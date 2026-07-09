#!/bin/bash
# Shared helpers for finalizing one Claude Code user turn as one trace.

_turn_json_string() {
    jq -Rs '.'
}

_turn_history_for_llm() {
    local history="$1"
    if echo "$history" | jq -e 'length > 0' >/dev/null 2>&1; then
        echo "$history"
    elif [ -n "${TURN_PROMPT:-}" ]; then
        jq -cn --arg p "$TURN_PROMPT" '[{role: "user", content: $p}]'
    else
        echo "[]"
    fi
}

_turn_extract_text_content() {
    local content="$1"
    if echo "$content" | jq -e '.' >/dev/null 2>&1; then
        echo "$content" | jq -r 'if type == "array" then [.[] | select(.type == "text") | .text] | join("\n") else . end' 2>/dev/null
    else
        echo "$content"
    fi
}

_turn_create_llm_span() {
    local output="$1" model="$2" prompt_tokens="$3" completion_tokens="$4" history="$5"
    local cache_create="${6:-0}" cache_read="${7:-0}" start_time="$8" end_time="$9"
    [ -z "$output" ] && return

    local span_id span_start span_end input_json output_json attrs span provider usage_meta history_json
    span_id=$(generate_span_id)
    span_end="${end_time:-$(get_time_nanos)}"
    span_start="${start_time:-${TURN_TASK_START:-$span_end}}"
    if [ "$span_start" -gt "$span_end" ] 2>/dev/null; then
        span_start="$span_end"
    fi

    provider=$(detect_provider "$model")
    history_json=$(_turn_history_for_llm "$history")
    input_json=$(echo "$history_json" | jq -c '.' | _turn_json_string)
    output_json=$(jq -n --arg c "$output" '[{role: "assistant", content: $c}]' | jq -c '.' | _turn_json_string)
    usage_meta=$(jq -n \
        --argjson inp "${prompt_tokens:-0}" \
        --argjson out "${completion_tokens:-0}" \
        --argjson cc "${cache_create:-0}" \
        --argjson cr "${cache_read:-0}" \
        '{input_tokens: $inp, output_tokens: $out, cache_creation_input_tokens: $cc, cache_read_input_tokens: $cr}' | jq -c '.')

    attrs=$(build_otlp_attributes "$(jq -n \
        --arg span_kind "llm" \
        --argjson input "$input_json" \
        --argjson output "$output_json" \
        --arg model "${model:-claude}" \
        --arg provider "$provider" \
        --argjson prompt "${prompt_tokens:-0}" \
        --argjson completion "${completion_tokens:-0}" \
        --argjson cache_create "${cache_create:-0}" \
        --argjson cache_read "${cache_read:-0}" \
        --arg usage_meta "$usage_meta" \
        --arg session_id "$TURN_SESSION_ID" \
        --argjson turn_index "${TURN_INDEX:-1}" \
        '{
          "judgment.span_kind": $span_kind,
          "judgment.input": $input,
          "judgment.output": $output,
          "judgment.llm.provider": $provider,
          "judgment.llm.model": $model,
          "judgment.usage.non_cached_input_tokens": $prompt,
          "judgment.usage.output_tokens": $completion,
          "judgment.usage.cache_creation_input_tokens": $cache_create,
          "judgment.usage.cache_read_input_tokens": $cache_read,
          "judgment.usage.metadata": $usage_meta,
          "judgment.session_id": $session_id,
          "session_id": $session_id,
          "turn_index": $turn_index
        }')"
    )
    span=$(build_otlp_span "$TURN_TRACE_ID" "$span_id" "$TURN_TASK_SPAN_ID" "${model:-anthropic.messages.create}" "llm" "$span_start" "$span_end" "$attrs" 20)
    if insert_span "$TURN_PROJECT_ID" "$span" >/dev/null; then
        TURN_LLM_CALLS=$((TURN_LLM_CALLS + 1))
        TURN_LAST_OUTPUT="$output"
        debug "LLM span: ${model:-claude}"
    fi
}

_turn_create_tool_span() {
    local tool_name="$1" tool_input="$2" tool_output="$3" start_time="$4" end_time="$5"
    [ -z "$tool_name" ] && return

    local span_id span_start span_end input_json output_json attrs span
    span_id=$(generate_span_id)
    span_end="${end_time:-$(get_time_nanos)}"
    span_start="${start_time:-$span_end}"
    if [ "$span_start" -gt "$span_end" ] 2>/dev/null; then
        span_start="$span_end"
    fi

    input_json=$(echo "$tool_input" | jq -c '.' 2>/dev/null | _turn_json_string)
    output_json=$(echo "$tool_output" | _turn_json_string)
    attrs=$(build_otlp_attributes "$(jq -n \
        --arg span_kind "tool" \
        --argjson input "$input_json" \
        --argjson output "$output_json" \
        --arg tool_name "$tool_name" \
        --arg session_id "$TURN_SESSION_ID" \
        --argjson turn_index "${TURN_INDEX:-1}" \
        '{
          "judgment.span_kind": $span_kind,
          "judgment.input": $input,
          "judgment.output": $output,
          "tool_name": $tool_name,
          "judgment.session_id": $session_id,
          "session_id": $session_id,
          "turn_index": $turn_index
        }')"
    )
    span=$(build_otlp_span "$TURN_TRACE_ID" "$span_id" "$TURN_TASK_SPAN_ID" "$tool_name" "tool" "$span_start" "$span_end" "$attrs" 20)
    if insert_span "$TURN_PROJECT_ID" "$span" >/dev/null; then
        TURN_TOOL_CALLS=$((TURN_TOOL_CALLS + 1))
        log "INFO" "Tool span: $tool_name"
    fi
}

parse_turn_transcript() {
    TURN_LLM_CALLS=0
    TURN_TOOL_CALLS=0
    TURN_LAST_OUTPUT=""
    TURN_TASK_INPUT="${TURN_PROMPT:-}"
    TURN_NEW_OFFSET="${TURN_OFFSET:-0}"

    local conv_file="$TURN_TRANSCRIPT_PATH"
    [ -n "$conv_file" ] && [ -f "$conv_file" ] || return 0

    local current_output="" current_model="" current_prompt_tokens=0 current_completion_tokens=0
    local current_cache_creation=0 current_cache_read=0 llm_start_time="" llm_end_time=""
    local conversation_history="[]" pending_tools="{}"

    while IFS= read -r line; do
        [ -z "$line" ] && continue

        local msg_type timestamp content content_type text usage
        msg_type=$(echo "$line" | jq -r '.type // empty' 2>/dev/null)
        timestamp=$(echo "$line" | jq -r '.timestamp // empty' 2>/dev/null)

        if [ "$msg_type" = "user" ]; then
            content=$(echo "$line" | jq -c '.message.content // empty' 2>/dev/null)
            content_type=""
            if echo "$content" | jq -e 'type == "array"' >/dev/null 2>&1; then
                content_type=$(echo "$content" | jq -r '.[0].type // empty' 2>/dev/null)
            fi

            if [ "$content_type" = "tool_result" ]; then
                if [ -n "$current_output" ]; then
                    _turn_create_llm_span "$current_output" "$current_model" "$current_prompt_tokens" "$current_completion_tokens" "$conversation_history" "$current_cache_creation" "$current_cache_read" "$llm_start_time" "$llm_end_time"
                    conversation_history=$(echo "$conversation_history" | jq --arg c "$current_output" '. += [{role: "assistant", content: $c}]')
                    current_output=""
                fi
                llm_start_time=$(iso_to_nanos "$timestamp")

                local tool_use_result
                tool_use_result=$(echo "$line" | jq -c '.toolUseResult // empty' 2>/dev/null)
                while IFS= read -r tool_result; do
                    [ -z "$tool_result" ] && continue
                    local tool_use_id tool_out pending p_name p_input p_start end_nanos raw_out tool_type file_content
                    tool_use_id=$(echo "$tool_result" | jq -r '.tool_use_id // empty')
                    if [ -n "$tool_use_result" ] && [ "$tool_use_result" != "null" ] && echo "$tool_use_result" | jq -e 'type == "object"' >/dev/null 2>&1; then
                        tool_type=$(echo "$tool_use_result" | jq -r '.type // empty')
                        if [ "$tool_type" = "text" ]; then
                            file_content=$(echo "$tool_use_result" | jq -r '.file.content // empty')
                            if [ -n "$file_content" ]; then
                                tool_out="$file_content"
                            else
                                tool_out=$(echo "$tool_use_result" | jq -r '.text // "completed"')
                            fi
                        else
                            tool_out=$(echo "$tool_use_result" | jq -c '.')
                        fi
                    elif [ -n "$tool_use_result" ] && [ "$tool_use_result" != "null" ]; then
                        tool_out=$(echo "$tool_use_result" | jq -r '.')
                    else
                        raw_out=$(echo "$tool_result" | jq -r '.content // "result"')
                        tool_out="${raw_out#*->}"
                    fi

                    if [ -n "$tool_use_id" ]; then
                        pending=$(echo "$pending_tools" | jq -r ".\"$tool_use_id\" // empty")
                        if [ -n "$pending" ] && [ "$pending" != "null" ]; then
                            p_name=$(echo "$pending" | jq -r '.name')
                            p_input=$(echo "$pending" | jq -r '.input')
                            p_start=$(echo "$pending" | jq -r '.start')
                            end_nanos=$(iso_to_nanos "$timestamp")
                            _turn_create_tool_span "$p_name" "$p_input" "$tool_out" "$p_start" "$end_nanos"
                            pending_tools=$(echo "$pending_tools" | jq "del(.\"$tool_use_id\")")
                        fi
                    fi
                done < <(echo "$content" | jq -c '.[]' 2>/dev/null)

                current_model=""
                current_prompt_tokens=0
                current_completion_tokens=0
                current_cache_creation=0
                current_cache_read=0
            else
                if [ -n "$current_output" ]; then
                    _turn_create_llm_span "$current_output" "$current_model" "$current_prompt_tokens" "$current_completion_tokens" "$conversation_history" "$current_cache_creation" "$current_cache_read" "$llm_start_time" "$llm_end_time"
                    conversation_history=$(echo "$conversation_history" | jq --arg c "$current_output" '. += [{role: "assistant", content: $c}]')
                    current_output=""
                fi
                text=$(_turn_extract_text_content "$content")
                if [ -n "$text" ]; then
                    conversation_history=$(echo "$conversation_history" | jq --arg c "$text" '. += [{role: "user", content: $c}]')
                    [ -z "$TURN_TASK_INPUT" ] && TURN_TASK_INPUT="$text"
                fi
                llm_start_time=$(iso_to_nanos "$timestamp")
                current_model=""
                current_prompt_tokens=0
                current_completion_tokens=0
                current_cache_creation=0
                current_cache_read=0
            fi
        elif [ "$msg_type" = "assistant" ]; then
            llm_end_time=$(iso_to_nanos "$timestamp")

            if echo "$line" | jq -e '.message.content | type == "array"' >/dev/null 2>&1; then
                while IFS= read -r tool_use; do
                    [ -z "$tool_use" ] && continue
                    local tool_id tool_name tool_input tool_start
                    tool_id=$(echo "$tool_use" | jq -r '.id // empty')
                    tool_name=$(echo "$tool_use" | jq -r '.name // empty')
                    tool_input=$(echo "$tool_use" | jq -c '.input // {}')
                    tool_start=$(iso_to_nanos "$timestamp")
                    if [ -n "$tool_id" ] && [ -n "$tool_name" ]; then
                        pending_tools=$(echo "$pending_tools" | jq --arg id "$tool_id" --arg name "$tool_name" --arg input "$tool_input" --arg start "$tool_start" \
                            '.[$id] = {name: $name, input: $input, start: $start}')
                    fi
                done < <(echo "$line" | jq -c '.message.content[] | select(.type == "tool_use")' 2>/dev/null)
            fi

            text=$(echo "$line" | jq -r '.message.content | if type == "array" then [.[] | select(.type == "text") | .text] | join("\n") else . end' 2>/dev/null)
            [ -n "$text" ] && current_output="${current_output:+$current_output$'\n'}$text"

            local model
            model=$(echo "$line" | jq -r '.message.model // .model // empty' 2>/dev/null)
            [ -n "$model" ] && current_model="$model"

            usage=$(echo "$line" | jq -c '.message.usage // .usage // {input_tokens: .input_tokens, output_tokens: .output_tokens, cache_creation_input_tokens: .cache_creation_input_tokens, cache_read_input_tokens: .cache_read_input_tokens} | select(. != null)' 2>/dev/null)
            if [ -n "$usage" ] && [ "$usage" != "{}" ] && [ "$usage" != "null" ]; then
                local inp out cc cr
                inp=$(echo "$usage" | jq -r '.input_tokens // 0')
                [ "$inp" != "null" ] && [ "$inp" -gt 0 ] 2>/dev/null && current_prompt_tokens=$inp
                out=$(echo "$usage" | jq -r '.output_tokens // 0')
                [ "$out" != "null" ] && [ "$out" -gt 0 ] 2>/dev/null && current_completion_tokens=$out
                cc=$(echo "$usage" | jq -r '.cache_creation_input_tokens // 0')
                [ "$cc" != "null" ] && [ "$cc" -gt 0 ] 2>/dev/null && current_cache_creation=$cc
                cr=$(echo "$usage" | jq -r '.cache_read_input_tokens // 0')
                [ "$cr" != "null" ] && [ "$cr" -gt 0 ] 2>/dev/null && current_cache_read=$cr
            fi
        fi
    done < <(tail -n +$(( ${TURN_OFFSET:-0} + 1 )) "$conv_file")

    if [ -n "$current_output" ]; then
        _turn_create_llm_span "$current_output" "$current_model" "$current_prompt_tokens" "$current_completion_tokens" "$conversation_history" "$current_cache_creation" "$current_cache_read" "$llm_start_time" "$llm_end_time"
    fi

    TURN_NEW_OFFSET=$(count_file_lines "$conv_file")
    return 0
}

finalize_turn_trace() {
    parse_turn_transcript

    local final_end final_output task_input_json task_attrs task_span root_attrs root_span
    final_end=$(get_time_nanos)
    final_output="${TURN_LAST_OUTPUT:-${TURN_FALLBACK_OUTPUT:-}}"

    if [ "$TURN_LLM_CALLS" -eq 0 ] && [ -n "$final_output" ]; then
        _turn_create_llm_span "$final_output" "${TURN_FALLBACK_MODEL:-claude}" 0 0 "[]" 0 0 "${TURN_TASK_START:-$final_end}" "$final_end"
    fi

    final_output="${TURN_LAST_OUTPUT:-${final_output:-Completed}}"
    task_input_json=$(echo "${TURN_TASK_INPUT:-${TURN_PROMPT:-}}" | _turn_json_string)

    task_attrs=$(build_otlp_attributes "$(jq -n \
        --arg span_kind "task" \
        --argjson input "$task_input_json" \
        --arg output "$final_output" \
        --argjson llm "$TURN_LLM_CALLS" \
        --argjson tools "$TURN_TOOL_CALLS" \
        --arg session_id "$TURN_SESSION_ID" \
        --argjson turn_index "${TURN_INDEX:-1}" \
        '{
          "judgment.span_kind": $span_kind,
          "judgment.input": $input,
          "judgment.output": $output,
          "llm_call_count": $llm,
          "tool_count": $tools,
          "judgment.session_id": $session_id,
          "session_id": $session_id,
          "turn_index": $turn_index
        }')"
    )
    task_span=$(build_otlp_span "$TURN_TRACE_ID" "$TURN_TASK_SPAN_ID" "$TURN_ROOT_SPAN_ID" "Task" "task" "${TURN_TASK_START:-$final_end}" "$final_end" "$task_attrs" 20)
    insert_span "$TURN_PROJECT_ID" "$task_span" >/dev/null || debug "Failed to finalize task span"

    root_attrs=$(build_otlp_attributes "$(jq -n \
        --arg span_kind "task" \
        --argjson input "$task_input_json" \
        --arg output "$final_output" \
        --arg session_id "$TURN_SESSION_ID" \
        --arg workspace "${TURN_WORKSPACE:-}" \
        --arg hostname "$(get_hostname)" \
        --arg username "$(get_username)" \
        --arg os "$(get_os)" \
        --argjson turn_index "${TURN_INDEX:-1}" \
        '{
          "judgment.span_kind": $span_kind,
          "judgment.input": $input,
          "judgment.output": $output,
          "judgment.session_id": $session_id,
          "session_id": $session_id,
          "turn_index": $turn_index,
          "workspace": $workspace,
          "hostname": $hostname,
          "username": $username,
          "os": $os,
          "source": "claude-code"
        }')"
    )
    root_span=$(build_otlp_span "$TURN_TRACE_ID" "$TURN_ROOT_SPAN_ID" "" "Claude Code Turn: ${TURN_WORKSPACE_NAME:-Claude Code}" "task" "${TURN_TRACE_START:-${TURN_TASK_START:-$final_end}}" "$final_end" "$root_attrs" 20)
    insert_span "$TURN_PROJECT_ID" "$root_span" >/dev/null || debug "Failed to finalize root span"

    log "INFO" "Trace finalized: $TURN_TRACE_ID (session=$TURN_SESSION_ID, turn=${TURN_INDEX:-1}, llm=$TURN_LLM_CALLS, tools=$TURN_TOOL_CALLS)"
    return 0
}
