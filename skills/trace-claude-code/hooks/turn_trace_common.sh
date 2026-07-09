#!/bin/bash
# Shared helpers for finalizing one Claude Code user turn as one trace.

_turn_json_string() {
    jq -Rs 'rtrimstr("\n")'
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

_turn_llm_output_text() {
    local text="$1" tool_uses="$2"
    if [ -n "$text" ]; then
        printf '%s\n' "$text"
        return
    fi
    echo "$tool_uses" | jq -r 'if type == "array" and length > 0 then "Tool use: " + ([.[] | .name // "tool"] | join(", ")) else "" end' 2>/dev/null
}

_turn_append_assistant_history() {
    local history="$1" text="$2" tool_uses="$3"
    if echo "$tool_uses" | jq -e 'type == "array" and length > 0' >/dev/null 2>&1; then
        echo "$history" | jq --arg c "$text" --argjson tools "$tool_uses" \
            '. += [{role: "assistant", content: $tools, text: $c, tool_uses: $tools}]'
    else
        echo "$history" | jq --arg c "$text" \
            '. += [{role: "assistant", content: [{type: "text", text: $c}], text: $c}]'
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

_turn_normalized_messages() {
    local file="$1" start_line="${2:-0}" end_line="${3:-0}" mode="${4:-all}"
    [ -n "$file" ] && [ -f "$file" ] || { echo "[]"; return; }

    jq -R -s \
        --argjson start "$start_line" \
        --argjson end "$end_line" \
        --arg mode "$mode" '
        def content_items:
          if . == null then []
          elif type == "array" then
            map(
              if .type == "text" then {type: "text", text: (.text // "")}
              elif .type == "tool_use" then {type: "tool_use", id: (.id // ""), name: (.name // ""), input: (.input // {})}
              elif .type == "tool_result" then {type: "tool_result", tool_use_id: (.tool_use_id // ""), content: (.content // "")}
              else .
              end
            )
          elif type == "string" then [{type: "text", text: .}]
          else [{type: "json", value: .}]
          end;
        def text_from_items($items):
          [$items[]? | select(.type == "text" and ((.text // "") | length) > 0) | .text] | join("\n");
        def normalize:
          .rec as $r
          | ($r.message.content | content_items) as $items
          | if $r.type == "user" then
              {
                role: (if (($items[0].type // "") == "tool_result") then "tool" else "user" end),
                timestamp: ($r.timestamp // ""),
                content: $items,
                text: text_from_items($items),
                tool_result: ($r.toolUseResult // null),
                uuid: ($r.uuid // ""),
                line: .line
              }
            elif $r.type == "assistant" then
              {
                role: "assistant",
                timestamp: ($r.timestamp // ""),
                content: $items,
                text: text_from_items($items),
                tool_uses: [$items[]? | select(.type == "tool_use")],
                model: ($r.message.model // $r.model // ""),
                uuid: ($r.uuid // ""),
                line: .line
              }
            elif $r.type == "system" then
              {
                role: "system",
                timestamp: ($r.timestamp // ""),
                content: $items,
                text: text_from_items($items),
                uuid: ($r.uuid // ""),
                line: .line
              }
            else empty end;
        split("\n")
        | to_entries
        | map(
            select(.value | length > 0)
            | {line: (.key + 1), rec: (.value | fromjson?)}
            | select(.rec != null)
            | select(.line > $start and (($end == 0) or (.line <= $end)))
            | normalize
            | select(
                (((.text // "") | length) > 0)
                or (((.tool_uses // []) | length) > 0)
                or (.role == "tool")
                or (.tool_result != null)
              )
            | select(
                if $mode == "input" then
                  (.role != "assistant") or (((.tool_uses // []) | length) > 0)
                elif $mode == "assistant" then
                  (.role == "assistant") and (((.text // "") | length) > 0)
                else true end
              )
          )
        ' "$file"
}

_turn_normalized_messages_through() {
    local file="$1" end_line="${2:-0}" mode="${3:-all}"
    if [ "${end_line:-0}" -gt 0 ] 2>/dev/null; then
        _turn_normalized_messages "$file" 0 "$end_line" "$mode"
    else
        echo "[]"
    fi
}

_turn_context_payload() {
    local messages_json="$1" current_output="${2:-}" include_output="${3:-false}"
    jq -cn \
        --argjson messages "$messages_json" \
        --arg session_id "$TURN_SESSION_ID" \
        --arg trace_id "$TURN_TRACE_ID" \
        --arg root_span_id "$TURN_ROOT_SPAN_ID" \
        --arg task_span_id "$TURN_TASK_SPAN_ID" \
        --argjson turn_index "${TURN_INDEX:-1}" \
        --arg workspace "${TURN_WORKSPACE:-}" \
        --arg current_prompt "${TURN_PROMPT:-}" \
        --arg output "$current_output" \
        --arg include_output "$include_output" \
        '{
          metadata: {
            session_id: $session_id,
            trace_id: $trace_id,
            root_span_id: $root_span_id,
            task_span_id: $task_span_id,
            turn_index: $turn_index,
            workspace: $workspace,
            source: "claude-code"
          },
          current_user_prompt: $current_prompt,
          messages: $messages
        }
        | if $include_output == "true" then . + {assistant_output: $output} else . end'
}

_turn_build_context_payloads() {
    local final_output="${1:-}"
    local prior_messages current_input_messages current_output_messages all_messages input_messages output_messages

    if [ -n "$TURN_TRANSCRIPT_PATH" ] && [ -f "$TURN_TRANSCRIPT_PATH" ]; then
        prior_messages=$(_turn_normalized_messages_through "$TURN_TRANSCRIPT_PATH" "${TURN_OFFSET:-0}" "all")
        current_input_messages=$(_turn_normalized_messages "$TURN_TRANSCRIPT_PATH" "${TURN_OFFSET:-0}" "${TURN_NEW_OFFSET:-0}" "input")
        current_output_messages=$(_turn_normalized_messages "$TURN_TRANSCRIPT_PATH" "${TURN_OFFSET:-0}" "${TURN_NEW_OFFSET:-0}" "assistant")
        all_messages=$(_turn_normalized_messages_through "$TURN_TRANSCRIPT_PATH" "${TURN_NEW_OFFSET:-0}" "all")
    else
        prior_messages="[]"
        current_input_messages=$(jq -cn --arg p "${TURN_PROMPT:-}" '[{role: "user", content: [{type: "text", text: $p}], text: $p}]')
        current_output_messages="[]"
        all_messages="$current_input_messages"
    fi

    input_messages=$(jq -cn --argjson prior "$prior_messages" --argjson current "$current_input_messages" '$prior + $current')
    output_messages="$all_messages"

    TURN_CONTEXT_INPUT_JSON=$(_turn_context_payload "$input_messages" "" "false")
    TURN_CONTEXT_OUTPUT_JSON=$(_turn_context_payload "$output_messages" "$final_output" "true")
}

_turn_create_llm_span() {
    local output="$1" model="$2" prompt_tokens="$3" completion_tokens="$4" history="$5"
    local cache_create="${6:-0}" cache_read="${7:-0}" start_time="$8" end_time="$9"
    local request_id="${10:-}"
    [ -z "$output" ] && return

    local span_id span_start span_end input_json output_json attrs span provider usage_meta history_json input_payload output_payload output_messages_json
    span_id=$(generate_span_id)
    span_end="${end_time:-$(get_time_nanos)}"
    span_start="${start_time:-${TURN_TASK_START:-$span_end}}"
    if [ "$span_start" -gt "$span_end" ] 2>/dev/null; then
        span_start="$span_end"
    fi

    provider=$(detect_provider "$model")
    history_json=$(_turn_history_for_llm "$history")

    local emitted_request_ids="${TURN_EMITTED_REQUEST_IDS:-}"
    [ -z "$emitted_request_ids" ] && emitted_request_ids="{}"
    if [ -n "$request_id" ] && echo "$emitted_request_ids" | jq -e --arg id "$request_id" '.[$id] == true' >/dev/null 2>&1; then
        debug "Skipping duplicate LLM span for requestId=$request_id"
        return
    fi

    input_payload=$(_turn_context_payload "$history_json" "" "false")
    output_messages_json=$(jq -cn \
        --argjson history "$history_json" \
        --arg c "$output" \
        --arg ts "$span_end" \
        '$history + [{role: "assistant", timestamp_nanos: $ts, content: [{type: "text", text: $c}], text: $c}]')
    output_payload=$(_turn_context_payload "$output_messages_json" "$output" "true")
    input_json=$(echo "$input_payload" | jq -c '.' | _turn_json_string)
    output_json=$(echo "$output_payload" | jq -c '.' | _turn_json_string)
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
        if [ -n "$request_id" ]; then
            TURN_EMITTED_REQUEST_IDS=$(echo "$emitted_request_ids" | jq --arg id "$request_id" '.[$id] = true')
        fi
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
        if [ "$tool_name" = "Agent" ]; then
            local subagent_task_id subagent_description subagent_key
            subagent_task_id=$(echo "$tool_output" | jq -r 'if type == "object" then .agentId // .agent_id // empty else empty end' 2>/dev/null)
            subagent_description=$(echo "$tool_input" | jq -r 'if type == "object" then .description // empty else empty end' 2>/dev/null)
            if [ -n "$subagent_task_id" ]; then
                subagent_key="subagent:$subagent_task_id"
                set_session_state_batch "$subagent_key" \
                    "parent_session_id" "$TURN_SESSION_ID" \
                    "trace_id" "$TURN_TRACE_ID" \
                    "project_id" "$TURN_PROJECT_ID" \
                    "root_span_id" "$TURN_ROOT_SPAN_ID" \
                    "task_span_id" "$TURN_TASK_SPAN_ID" \
                    "tool_span_id" "$span_id" \
                    "trace_start" "${TURN_TRACE_START:-}" \
                    "task_start" "${TURN_TASK_START:-}" \
                    "turn_index" "${TURN_INDEX:-1}" \
                    "workspace" "${TURN_WORKSPACE:-}" \
                    "description" "${subagent_description:-$tool_name}"
                debug "Mapped subagent task $subagent_task_id to trace $TURN_TRACE_ID"
            fi
        fi
    fi
}

parse_turn_transcript() {
    TURN_LLM_CALLS=0
    TURN_TOOL_CALLS=0
    TURN_LAST_OUTPUT=""
    TURN_TASK_INPUT="${TURN_PROMPT:-}"
    TURN_NEW_OFFSET="${TURN_OFFSET:-0}"
    TURN_EMITTED_REQUEST_IDS="{}"

    local conv_file="$TURN_TRANSCRIPT_PATH"
    [ -n "$conv_file" ] && [ -f "$conv_file" ] || return 0

    local current_output="" current_model="" current_prompt_tokens=0 current_completion_tokens=0
    local current_cache_creation=0 current_cache_read=0 llm_start_time="" llm_end_time="" current_request_id=""
    local conversation_history pending_tools="{}" current_tool_uses="[]" llm_output
    conversation_history=$(_turn_normalized_messages_through "$conv_file" "${TURN_OFFSET:-0}" "all")

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
                llm_output=$(_turn_llm_output_text "$current_output" "$current_tool_uses")
                if [ -n "$llm_output" ]; then
                    _turn_create_llm_span "$llm_output" "$current_model" "$current_prompt_tokens" "$current_completion_tokens" "$conversation_history" "$current_cache_creation" "$current_cache_read" "$llm_start_time" "$llm_end_time" "$current_request_id"
                    conversation_history=$(_turn_append_assistant_history "$conversation_history" "$current_output" "$current_tool_uses")
                    current_output=""
                    current_tool_uses="[]"
                    current_request_id=""
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
                    conversation_history=$(echo "$conversation_history" | jq \
                        --arg ts "$timestamp" \
                        --arg id "$tool_use_id" \
                        --arg c "$tool_out" \
                        '. += [{role: "tool", timestamp: $ts, tool_use_id: $id, content: [{type: "tool_result", content: $c}], text: $c}]')
                done < <(echo "$content" | jq -c '.[]' 2>/dev/null)

                current_model=""
                current_prompt_tokens=0
                current_completion_tokens=0
                current_cache_creation=0
                current_cache_read=0
                current_request_id=""
            else
                llm_output=$(_turn_llm_output_text "$current_output" "$current_tool_uses")
                if [ -n "$llm_output" ]; then
                    _turn_create_llm_span "$llm_output" "$current_model" "$current_prompt_tokens" "$current_completion_tokens" "$conversation_history" "$current_cache_creation" "$current_cache_read" "$llm_start_time" "$llm_end_time" "$current_request_id"
                    conversation_history=$(_turn_append_assistant_history "$conversation_history" "$current_output" "$current_tool_uses")
                    current_output=""
                    current_tool_uses="[]"
                    current_request_id=""
                fi
                text=$(_turn_extract_text_content "$content")
                if [ -n "$text" ]; then
                    conversation_history=$(echo "$conversation_history" | jq --arg ts "$timestamp" --arg c "$text" '. += [{role: "user", timestamp: $ts, content: [{type: "text", text: $c}], text: $c}]')
                    [ -z "$TURN_TASK_INPUT" ] && TURN_TASK_INPUT="$text"
                fi
                llm_start_time=$(iso_to_nanos "$timestamp")
                current_model=""
                current_prompt_tokens=0
                current_completion_tokens=0
                current_cache_creation=0
                current_cache_read=0
                current_tool_uses="[]"
                current_request_id=""
            fi
        elif [ "$msg_type" = "assistant" ]; then
            llm_end_time=$(iso_to_nanos "$timestamp")
            local request_id
            request_id=$(echo "$line" | jq -r '.requestId // .request_id // empty' 2>/dev/null)
            [ -n "$request_id" ] && current_request_id="$request_id"

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
                        current_tool_uses=$(echo "$current_tool_uses" | jq --arg id "$tool_id" --arg name "$tool_name" --argjson input "$tool_input" \
                            '. += [{type: "tool_use", id: $id, name: $name, input: $input}]')
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

    llm_output=$(_turn_llm_output_text "$current_output" "$current_tool_uses")
    if [ -n "$llm_output" ]; then
        _turn_create_llm_span "$llm_output" "$current_model" "$current_prompt_tokens" "$current_completion_tokens" "$conversation_history" "$current_cache_creation" "$current_cache_read" "$llm_start_time" "$llm_end_time" "$current_request_id"
    fi

    TURN_NEW_OFFSET=$(count_file_lines "$conv_file")
    return 0
}

finalize_turn_trace() {
    parse_turn_transcript

    local final_end final_output task_input_json task_output_json task_attrs task_span root_attrs root_span
    final_end=$(get_time_nanos)
    final_output="${TURN_LAST_OUTPUT:-${TURN_FALLBACK_OUTPUT:-}}"

    if [ "$TURN_LLM_CALLS" -eq 0 ] && [ -n "$final_output" ]; then
        _turn_create_llm_span "$final_output" "${TURN_FALLBACK_MODEL:-claude}" 0 0 "[]" 0 0 "${TURN_TASK_START:-$final_end}" "$final_end"
    fi

    final_output="${TURN_LAST_OUTPUT:-${final_output:-Completed}}"
    _turn_build_context_payloads "$final_output"
    task_input_json=$(echo "$TURN_CONTEXT_INPUT_JSON" | jq -c '.' | _turn_json_string)
    task_output_json=$(echo "$TURN_CONTEXT_OUTPUT_JSON" | jq -c '.' | _turn_json_string)

    task_attrs=$(build_otlp_attributes "$(jq -n \
        --arg span_kind "task" \
        --argjson input "$task_input_json" \
        --argjson output "$task_output_json" \
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
        --argjson output "$task_output_json" \
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

    TURN_FINAL_END="$final_end"
    TURN_TASK_INPUT_ATTR_JSON="$task_input_json"
    TURN_TASK_OUTPUT_ATTR_JSON="$task_output_json"

    log "INFO" "Trace finalized: $TURN_TRACE_ID (session=$TURN_SESSION_ID, turn=${TURN_INDEX:-1}, llm=$TURN_LLM_CALLS, tools=$TURN_TOOL_CALLS)"
    return 0
}
