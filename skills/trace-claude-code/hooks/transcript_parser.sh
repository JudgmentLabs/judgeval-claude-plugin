#!/bin/bash
###
# Shared transcript parser
#
# Converts Claude Code transcript JSONL lines into LLM and tool spans.
# Used incrementally by stop_hook.sh (per turn, from a saved line offset)
# and by session_end.sh (final sweep for anything the last turn missed).
#
# Inputs (globals, set by caller):
#   PARSE_FILE            transcript path
#   PARSE_OFFSET          number of lines already processed (default 0)
#   PARSE_TRACE_ID        trace id spans belong to
#   PARSE_PROJECT_ID      project id spans are posted to
#   PARSE_PARENT_SPAN_ID  parent span id for created llm/tool spans
#   PARSE_HISTORY_FILE    optional path persisting conversation history
#                         across turns (so llm span inputs include prior turns)
#
# Outputs (globals):
#   PARSE_LLM_CALLS PARSE_TOOL_CALLS PARSE_NEW_OFFSET
#   PARSE_LAST_OUTPUT PARSE_FIRST_USER_INPUT
#   PARSE_FIRST_TS_NANOS PARSE_LAST_TS_NANOS
###

_parser_create_llm_span() {
    local output="$1" model="$2" prompt="$3" completion="$4" history="$5"
    local cache_create="${6:-0}" cache_read="${7:-0}" start_time="$8" end_time="$9"
    # An LLM call whose response is only tool_use blocks has no text output
    # but still consumed tokens and must appear in the trace.
    if [ -z "$output" ]; then
        [ -z "$model" ] && return 0
        local tool_names
        tool_names=$(echo "$PENDING_TOOLS" | jq -r '[.[].name] | join(", ")' 2>/dev/null)
        output="[tool call: ${tool_names:-unknown}]"
    fi
    local span_id span_start span_end input_json output_json attrs span duration_ms provider
    span_id=$(generate_uuid | sed 's/-//g' | head -c 16)
    span_start="${start_time:-$(get_time_nanos)}"
    span_end="${end_time:-$(get_time_nanos)}"
    provider=$(detect_provider "$model")
    input_json=$(echo "$history" | jq -c '.' | jq -Rs '.')
    output_json=$(jq -n --arg c "$output" '[{role: "assistant", content: $c}]' | jq -c '.' | jq -Rs '.')
    local usage_meta
    usage_meta=$(jq -n --argjson inp "$prompt" --argjson out "$completion" \
        --argjson cc "$cache_create" --argjson cr "$cache_read" \
        '{input_tokens: $inp, output_tokens: $out, cache_creation_input_tokens: $cc, cache_read_input_tokens: $cr}' | jq -c '.')
    attrs=$(build_otlp_attributes "$(jq -n \
        --arg span_kind "llm" --argjson input "$input_json" --argjson output "$output_json" \
        --arg model "${model:-claude}" --arg provider "$provider" \
        --argjson prompt "$prompt" --argjson completion "$completion" \
        --argjson cache_create "$cache_create" --argjson cache_read "$cache_read" \
        --arg usage_meta "$usage_meta" \
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
          "judgment.usage.metadata": $usage_meta
        }')")
    span=$(build_otlp_span "$PARSE_TRACE_ID" "$span_id" "$PARSE_PARENT_SPAN_ID" "${model:-anthropic.messages.create}" "llm" "$span_start" "$span_end" "$attrs" 20)
    duration_ms=$(( (span_end - span_start) / 1000000 ))
    if insert_span "$PARSE_PROJECT_ID" "$span" >/dev/null; then
        PARSE_LLM_CALLS=$((PARSE_LLM_CALLS + 1))
        debug "LLM span: $model (${duration_ms}ms) tokens: in=$prompt out=$completion cache_create=$cache_create cache_read=$cache_read"
    fi
    return 0
}

_parser_create_tool_span() {
    local tool_name="$1" tool_input="$2" tool_output="$3" start_time="$4" end_time="$5"
    [ -z "$tool_name" ] && return 0
    local span_id input_json output_json attrs span
    span_id=$(generate_uuid | sed 's/-//g' | head -c 16)
    input_json=$(echo "$tool_input" | jq -c '.' 2>/dev/null | jq -Rs '.')
    output_json=$(echo "$tool_output" | jq -Rs '.')
    attrs=$(build_otlp_attributes "$(jq -n --arg span_kind "tool" --argjson input "$input_json" --argjson output "$output_json" --arg tool_name "$tool_name" \
        '{"judgment.span_kind": $span_kind, "judgment.input": $input, "judgment.output": $output, "tool_name": $tool_name}')")
    span=$(build_otlp_span "$PARSE_TRACE_ID" "$span_id" "$PARSE_PARENT_SPAN_ID" "$tool_name" "tool" "$start_time" "$end_time" "$attrs" 20)
    if insert_span "$PARSE_PROJECT_ID" "$span" >/dev/null; then
        PARSE_TOOL_CALLS=$((PARSE_TOOL_CALLS + 1))
        log "INFO" "Tool span: $tool_name ($(( (end_time - start_time) / 1000000 ))ms)"
    fi
    return 0
}

parse_transcript_chunk() {
    PARSE_LLM_CALLS=0
    PARSE_TOOL_CALLS=0
    PARSE_LAST_OUTPUT=""
    PARSE_FIRST_USER_INPUT=""
    PARSE_FIRST_TS_NANOS=""
    PARSE_LAST_TS_NANOS=""
    PARSE_NEW_OFFSET="${PARSE_OFFSET:-0}"

    if [ -z "$PARSE_FILE" ] || [ ! -f "$PARSE_FILE" ]; then
        debug "Parser: no transcript file"
        return 0
    fi

    local CURRENT_OUTPUT="" CURRENT_MODEL=""
    local CURRENT_PROMPT_TOKENS=0 CURRENT_COMPLETION_TOKENS=0
    local CURRENT_CACHE_CREATION=0 CURRENT_CACHE_READ=0
    local LLM_START_TIME="" LLM_END_TIME=""
    local PENDING_TOOLS="{}"
    local CONVERSATION_HISTORY="[]"

    if [ -n "$PARSE_HISTORY_FILE" ] && [ -f "$PARSE_HISTORY_FILE" ]; then
        CONVERSATION_HISTORY=$(cat "$PARSE_HISTORY_FILE" 2>/dev/null)
        echo "$CONVERSATION_HISTORY" | jq -e '.' >/dev/null 2>&1 || CONVERSATION_HISTORY="[]"
    fi

    local line MSG_TYPE TIMESTAMP TS_NANOS CONTENT CONTENT_TYPE
    while IFS= read -r line; do
        PARSE_NEW_OFFSET=$((PARSE_NEW_OFFSET + 1))
        [ -z "$line" ] && continue

        # Subagent (sidechain) messages are traced by subagent_stop.sh
        echo "$line" | jq -e '.isSidechain == true' >/dev/null 2>&1 && continue

        MSG_TYPE=$(echo "$line" | jq -r '.type // empty' 2>/dev/null)
        TIMESTAMP=$(echo "$line" | jq -r '.timestamp // empty' 2>/dev/null)
        if [ -n "$TIMESTAMP" ]; then
            TS_NANOS=$(iso_to_nanos "$TIMESTAMP")
            if [ -n "$TS_NANOS" ] && [ "$TS_NANOS" -gt 0 ] 2>/dev/null; then
                [ -z "$PARSE_FIRST_TS_NANOS" ] && PARSE_FIRST_TS_NANOS="$TS_NANOS"
                PARSE_LAST_TS_NANOS="$TS_NANOS"
            fi
        fi

        if [ "$MSG_TYPE" = "user" ]; then
            CONTENT=$(echo "$line" | jq -c '.message.content // empty' 2>/dev/null)
            CONTENT_TYPE=""
            if echo "$CONTENT" | jq -e 'type == "array"' >/dev/null 2>&1; then
                CONTENT_TYPE=$(echo "$CONTENT" | jq -r '.[0].type // empty' 2>/dev/null)
            fi

            if [ "$CONTENT_TYPE" = "tool_result" ]; then
                if [ -n "$CURRENT_OUTPUT" ] || [ -n "$CURRENT_MODEL" ]; then
                    _parser_create_llm_span "$CURRENT_OUTPUT" "$CURRENT_MODEL" "$CURRENT_PROMPT_TOKENS" "$CURRENT_COMPLETION_TOKENS" "$CONVERSATION_HISTORY" "$CURRENT_CACHE_CREATION" "$CURRENT_CACHE_READ" "$LLM_START_TIME" "$LLM_END_TIME"
                    if [ -n "$CURRENT_OUTPUT" ]; then
                        CONVERSATION_HISTORY=$(echo "$CONVERSATION_HISTORY" | jq --arg c "$CURRENT_OUTPUT" '. += [{role: "assistant", content: $c}]')
                        PARSE_LAST_OUTPUT="$CURRENT_OUTPUT"
                    fi
                    CURRENT_OUTPUT=""
                fi
                LLM_START_TIME=$(iso_to_nanos "$TIMESTAMP")

                local TOOL_USE_RESULT TOOL_RESULT TOOL_USE_ID TOOL_TYPE FILE_CONTENT TOOL_OUT RAW_OUT PENDING P_NAME P_INPUT P_START END_NANOS
                TOOL_USE_RESULT=$(echo "$line" | jq -c '.toolUseResult // empty' 2>/dev/null)

                while IFS= read -r TOOL_RESULT; do
                    [ -z "$TOOL_RESULT" ] && continue
                    TOOL_USE_ID=$(echo "$TOOL_RESULT" | jq -r '.tool_use_id // empty')

                    if [ -n "$TOOL_USE_RESULT" ] && [ "$TOOL_USE_RESULT" != "null" ] && echo "$TOOL_USE_RESULT" | jq -e 'type == "object"' >/dev/null 2>&1; then
                        TOOL_TYPE=$(echo "$TOOL_USE_RESULT" | jq -r '.type // empty')
                        if [ "$TOOL_TYPE" = "text" ]; then
                            FILE_CONTENT=$(echo "$TOOL_USE_RESULT" | jq -r '.file.content // empty')
                            if [ -n "$FILE_CONTENT" ]; then
                                TOOL_OUT="$FILE_CONTENT"
                            else
                                TOOL_OUT=$(echo "$TOOL_USE_RESULT" | jq -r '.text // "completed"')
                            fi
                        else
                            TOOL_OUT=$(echo "$TOOL_USE_RESULT" | jq -c '.')
                        fi
                    elif [ -n "$TOOL_USE_RESULT" ] && [ "$TOOL_USE_RESULT" != "null" ]; then
                        TOOL_OUT=$(echo "$TOOL_USE_RESULT" | jq -r '.')
                    else
                        RAW_OUT=$(echo "$TOOL_RESULT" | jq -r '.content // "result"')
                        TOOL_OUT="${RAW_OUT#*→}"
                    fi

                    if [ -n "$TOOL_USE_ID" ]; then
                        PENDING=$(echo "$PENDING_TOOLS" | jq -r ".\"$TOOL_USE_ID\" // empty")
                        if [ -n "$PENDING" ] && [ "$PENDING" != "null" ]; then
                            P_NAME=$(echo "$PENDING" | jq -r '.name')
                            P_INPUT=$(echo "$PENDING" | jq -r '.input')
                            P_START=$(echo "$PENDING" | jq -r '.start')
                            if [ -n "$P_START" ] && [ "$P_START" != "null" ] && [ "$P_START" -gt 0 ] 2>/dev/null; then
                                END_NANOS=$(iso_to_nanos "$TIMESTAMP")
                                if [ -n "$END_NANOS" ] && [ "$END_NANOS" -gt 0 ] 2>/dev/null; then
                                    _parser_create_tool_span "$P_NAME" "$P_INPUT" "$TOOL_OUT" "$P_START" "$END_NANOS"
                                fi
                            fi
                            PENDING_TOOLS=$(echo "$PENDING_TOOLS" | jq "del(.\"$TOOL_USE_ID\")")
                        fi
                    fi
                done < <(echo "$CONTENT" | jq -c '.[]' 2>/dev/null)
                CURRENT_MODEL=""; CURRENT_PROMPT_TOKENS=0; CURRENT_COMPLETION_TOKENS=0; CURRENT_CACHE_CREATION=0; CURRENT_CACHE_READ=0
            else
                if [ -n "$CURRENT_OUTPUT" ]; then
                    _parser_create_llm_span "$CURRENT_OUTPUT" "$CURRENT_MODEL" "$CURRENT_PROMPT_TOKENS" "$CURRENT_COMPLETION_TOKENS" "$CONVERSATION_HISTORY" "$CURRENT_CACHE_CREATION" "$CURRENT_CACHE_READ" "$LLM_START_TIME" "$LLM_END_TIME"
                    CONVERSATION_HISTORY=$(echo "$CONVERSATION_HISTORY" | jq --arg c "$CURRENT_OUTPUT" '. += [{role: "assistant", content: $c}]')
                    PARSE_LAST_OUTPUT="$CURRENT_OUTPUT"
                fi
                if [ "$CONTENT" != "null" ] && [ -n "$CONTENT" ]; then
                    local TXT="$CONTENT"
                    if echo "$CONTENT" | jq -e '.' >/dev/null 2>&1; then
                        TXT=$(echo "$CONTENT" | jq -r 'if type == "array" then [.[] | select(.type == "text") | .text] | join("\n") else . end' 2>/dev/null)
                    fi
                    [ -n "$TXT" ] && CONVERSATION_HISTORY=$(echo "$CONVERSATION_HISTORY" | jq --arg c "$TXT" '. += [{role: "user", content: $c}]')
                    [ -z "$PARSE_FIRST_USER_INPUT" ] && [ -n "$TXT" ] && PARSE_FIRST_USER_INPUT="$TXT"
                fi
                LLM_START_TIME=$(iso_to_nanos "$TIMESTAMP")
                CURRENT_OUTPUT=""; CURRENT_MODEL=""; CURRENT_PROMPT_TOKENS=0; CURRENT_COMPLETION_TOKENS=0; CURRENT_CACHE_CREATION=0; CURRENT_CACHE_READ=0
            fi
        elif [ "$MSG_TYPE" = "assistant" ]; then
            LLM_END_TIME=$(iso_to_nanos "$TIMESTAMP")

            if echo "$line" | jq -e '.message.content | type == "array"' >/dev/null 2>&1; then
                local TOOL_USE TOOL_ID TOOL_NAME TOOL_INPUT
                while IFS= read -r TOOL_USE; do
                    [ -z "$TOOL_USE" ] && continue
                    TOOL_ID=$(echo "$TOOL_USE" | jq -r '.id // empty')
                    TOOL_NAME=$(echo "$TOOL_USE" | jq -r '.name // empty')
                    TOOL_INPUT=$(echo "$TOOL_USE" | jq -c '.input // {}')
                    if [ -n "$TOOL_ID" ] && [ -n "$TOOL_NAME" ]; then
                        PENDING_TOOLS=$(echo "$PENDING_TOOLS" | jq --arg id "$TOOL_ID" --arg name "$TOOL_NAME" --arg input "$TOOL_INPUT" --arg start "$(iso_to_nanos "$TIMESTAMP")" \
                            '.[$id] = {name: $name, input: $input, start: $start}')
                    fi
                done < <(echo "$line" | jq -c '.message.content[] | select(.type == "tool_use")' 2>/dev/null)
            fi
            local TEXT MODEL USAGE INP OUT CC CR
            TEXT=$(echo "$line" | jq -r '.message.content | if type == "array" then [.[] | select(.type == "text") | .text] | join("\n") else . end' 2>/dev/null)
            [ -n "$TEXT" ] && CURRENT_OUTPUT="${CURRENT_OUTPUT:+$CURRENT_OUTPUT$'\n'}$TEXT"
            MODEL=$(echo "$line" | jq -r '.message.model // .model // empty' 2>/dev/null)
            [ -n "$MODEL" ] && CURRENT_MODEL="$MODEL"
            # Claude Code repeats the same cumulative usage on every assistant content block
            # within a single API call, so use the latest values (replace) instead of accumulating
            USAGE=$(echo "$line" | jq -c '.message.usage // .usage // {input_tokens: .input_tokens, output_tokens: .output_tokens, cache_creation_input_tokens: .cache_creation_input_tokens, cache_read_input_tokens: .cache_read_input_tokens} | select(. != null)' 2>/dev/null)
            if [ -n "$USAGE" ] && [ "$USAGE" != "{}" ] && [ "$USAGE" != "null" ]; then
                INP=$(echo "$USAGE" | jq -r '.input_tokens // 0')
                [ "$INP" != "null" ] && [ "$INP" -gt 0 ] 2>/dev/null && CURRENT_PROMPT_TOKENS=$INP
                OUT=$(echo "$USAGE" | jq -r '.output_tokens // 0')
                [ "$OUT" != "null" ] && [ "$OUT" -gt 0 ] 2>/dev/null && CURRENT_COMPLETION_TOKENS=$OUT
                CC=$(echo "$USAGE" | jq -r '.cache_creation_input_tokens // 0')
                [ "$CC" != "null" ] && [ "$CC" -gt 0 ] 2>/dev/null && CURRENT_CACHE_CREATION=$CC
                CR=$(echo "$USAGE" | jq -r '.cache_read_input_tokens // 0')
                [ "$CR" != "null" ] && [ "$CR" -gt 0 ] 2>/dev/null && CURRENT_CACHE_READ=$CR
            fi
        fi
    done < <(tail -n +$(( ${PARSE_OFFSET:-0} + 1 )) "$PARSE_FILE")

    if [ -n "$CURRENT_OUTPUT" ]; then
        _parser_create_llm_span "$CURRENT_OUTPUT" "$CURRENT_MODEL" "$CURRENT_PROMPT_TOKENS" "$CURRENT_COMPLETION_TOKENS" "$CONVERSATION_HISTORY" "$CURRENT_CACHE_CREATION" "$CURRENT_CACHE_READ" "$LLM_START_TIME" "$LLM_END_TIME"
        CONVERSATION_HISTORY=$(echo "$CONVERSATION_HISTORY" | jq --arg c "$CURRENT_OUTPUT" '. += [{role: "assistant", content: $c}]')
        PARSE_LAST_OUTPUT="$CURRENT_OUTPUT"
    fi

    if [ -n "$PARSE_HISTORY_FILE" ]; then
        echo "$CONVERSATION_HISTORY" > "$PARSE_HISTORY_FILE" 2>/dev/null || true
    fi
    return 0
}
