#!/bin/bash
###
# Shared transcript parser
#
# Converts Claude Code transcript JSONL lines into LLM and tool spans.
# Used incrementally by stop_hook.sh (per turn, from a saved line offset)
# and by session_end.sh (final sweep for anything the last turn missed).
#
# LLM span inputs/outputs preserve the provider message format: assistant
# content is the raw content-block array (text + tool_use), and tool results
# are kept in the conversation history as tool_result user messages, so the
# recorded context window matches what actually went to the model as closely
# as the transcript allows. (The true system prompt and tool definitions are
# not present in the transcript and cannot be captured from hooks.)
#
# Inputs (globals, set by caller):
#   PARSE_FILE            transcript path
#   PARSE_OFFSET          number of lines already processed (default 0)
#   PARSE_TRACE_ID        trace id spans belong to
#   PARSE_PROJECT_ID      project id spans are posted to
#   PARSE_PARENT_SPAN_ID  parent span id for created llm/tool spans
#   PARSE_SESSION_ID      session id stamped on created spans
#   PARSE_HISTORY_FILE    optional path persisting conversation history
#                         across turns (so llm span inputs include prior turns)
#
# Outputs (globals):
#   PARSE_LLM_CALLS PARSE_TOOL_CALLS PARSE_NEW_OFFSET
#   PARSE_LAST_OUTPUT PARSE_FIRST_USER_INPUT
#   PARSE_FIRST_TS_NANOS PARSE_LAST_TS_NANOS
###

# Flushes the accumulated assistant response (raw content blocks + usage)
# as an llm span, and appends it to the conversation history.
# Reads/writes parser globals; resets the per-call accumulators.
_parser_flush_llm_span() {
    local content_len
    content_len=$(echo "$CURRENT_CONTENT" | jq 'length' 2>/dev/null || echo 0)
    if [ "$content_len" -eq 0 ] 2>/dev/null && [ -z "$CURRENT_MODEL" ]; then
        return 0
    fi
    [ "$content_len" -eq 0 ] 2>/dev/null && CURRENT_CONTENT='[{"type":"text","text":""}]'

    local span_id span_start span_end input_json output_json attrs span duration_ms provider
    span_id=$(generate_uuid | sed 's/-//g' | head -c 16)
    span_start="${LLM_START_TIME:-$(get_time_nanos)}"
    span_end="${LLM_END_TIME:-$(get_time_nanos)}"
    provider=$(detect_provider "$CURRENT_MODEL")
    input_json=$(echo "$CONVERSATION_HISTORY" | jq -c '.' | jq -Rs '.')
    output_json=$(jq -cn --argjson c "$CURRENT_CONTENT" '[{role: "assistant", content: $c}]' | jq -Rs '.')
    local usage_meta
    usage_meta=$(jq -n --argjson inp "$CURRENT_PROMPT_TOKENS" --argjson out "$CURRENT_COMPLETION_TOKENS" \
        --argjson cc "$CURRENT_CACHE_CREATION" --argjson cr "$CURRENT_CACHE_READ" \
        '{input_tokens: $inp, output_tokens: $out, cache_creation_input_tokens: $cc, cache_read_input_tokens: $cr}' | jq -c '.')
    attrs=$(build_otlp_attributes "$(jq -n \
        --arg span_kind "llm" --argjson input "$input_json" --argjson output "$output_json" \
        --arg model "${CURRENT_MODEL:-claude}" --arg provider "$provider" \
        --argjson prompt "$CURRENT_PROMPT_TOKENS" --argjson completion "$CURRENT_COMPLETION_TOKENS" \
        --argjson cache_create "$CURRENT_CACHE_CREATION" --argjson cache_read "$CURRENT_CACHE_READ" \
        --arg usage_meta "$usage_meta" --arg session_id "${PARSE_SESSION_ID:-}" \
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
          "judgment.session_id": $session_id
        }')")
    span=$(build_otlp_span "$PARSE_TRACE_ID" "$span_id" "$PARSE_PARENT_SPAN_ID" "${CURRENT_MODEL:-anthropic.messages.create}" "llm" "$span_start" "$span_end" "$attrs" 20)
    duration_ms=$(( (span_end - span_start) / 1000000 ))
    if insert_span "$PARSE_PROJECT_ID" "$span" >/dev/null; then
        PARSE_LLM_CALLS=$((PARSE_LLM_CALLS + 1))
        debug "LLM span: $CURRENT_MODEL (${duration_ms}ms) tokens: in=$CURRENT_PROMPT_TOKENS out=$CURRENT_COMPLETION_TOKENS cache_create=$CURRENT_CACHE_CREATION cache_read=$CURRENT_CACHE_READ"
    fi

    CONVERSATION_HISTORY=$(jq -cn --argjson h "$CONVERSATION_HISTORY" --argjson c "$CURRENT_CONTENT" \
        '$h + [{role: "assistant", content: $c}]')
    [ -n "$CURRENT_OUTPUT" ] && PARSE_LAST_OUTPUT="$CURRENT_OUTPUT"
    CURRENT_CONTENT="[]"
    CURRENT_OUTPUT=""
    return 0
}

_parser_create_tool_span() {
    local tool_name="$1" tool_input="$2" tool_output="$3" start_time="$4" end_time="$5"
    [ -z "$tool_name" ] && return 0
    local span_id input_json output_json attrs span
    span_id=$(generate_uuid | sed 's/-//g' | head -c 16)
    input_json=$(echo "$tool_input" | jq -c '.' 2>/dev/null | jq -Rs '.')
    output_json=$(echo "$tool_output" | jq -Rs '.')
    attrs=$(build_otlp_attributes "$(jq -n --arg span_kind "tool" --argjson input "$input_json" --argjson output "$output_json" --arg tool_name "$tool_name" --arg session_id "${PARSE_SESSION_ID:-}" \
        '{"judgment.span_kind": $span_kind, "judgment.input": $input, "judgment.output": $output, "tool_name": $tool_name, "judgment.session_id": $session_id}')")
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

    CURRENT_CONTENT="[]"
    CURRENT_OUTPUT=""
    CURRENT_MODEL=""
    CURRENT_PROMPT_TOKENS=0
    CURRENT_COMPLETION_TOKENS=0
    CURRENT_CACHE_CREATION=0
    CURRENT_CACHE_READ=0
    LLM_START_TIME=""
    LLM_END_TIME=""
    local PENDING_TOOLS="{}"
    CONVERSATION_HISTORY="[]"

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
                _parser_flush_llm_span
                # Keep the tool results in the recorded context window,
                # exactly as they went back to the model.
                CONVERSATION_HISTORY=$(jq -cn --argjson h "$CONVERSATION_HISTORY" --argjson c "$CONTENT" \
                    '$h + [{role: "user", content: $c}]' 2>/dev/null || echo "$CONVERSATION_HISTORY")
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
                _parser_flush_llm_span
                if [ "$CONTENT" != "null" ] && [ -n "$CONTENT" ]; then
                    local TXT="$CONTENT"
                    if echo "$CONTENT" | jq -e '.' >/dev/null 2>&1; then
                        TXT=$(echo "$CONTENT" | jq -r 'if type == "array" then [.[] | select(.type == "text") | .text] | join("\n") else . end' 2>/dev/null)
                    fi
                    [ -n "$TXT" ] && CONVERSATION_HISTORY=$(echo "$CONVERSATION_HISTORY" | jq --arg c "$TXT" '. += [{role: "user", content: $c}]')
                    [ -z "$PARSE_FIRST_USER_INPUT" ] && [ -n "$TXT" ] && PARSE_FIRST_USER_INPUT="$TXT"
                fi
                LLM_START_TIME=$(iso_to_nanos "$TIMESTAMP")
                CURRENT_MODEL=""; CURRENT_PROMPT_TOKENS=0; CURRENT_COMPLETION_TOKENS=0; CURRENT_CACHE_CREATION=0; CURRENT_CACHE_READ=0
            fi
        elif [ "$MSG_TYPE" = "assistant" ]; then
            LLM_END_TIME=$(iso_to_nanos "$TIMESTAMP")

            # Accumulate the raw provider content blocks (text + tool_use),
            # normalizing plain-string content into a text block.
            local RAW_CONTENT
            RAW_CONTENT=$(echo "$line" | jq -c '.message.content // empty' 2>/dev/null)
            if [ -n "$RAW_CONTENT" ] && [ "$RAW_CONTENT" != "null" ]; then
                RAW_CONTENT=$(echo "$RAW_CONTENT" | jq -c 'if type == "string" then [{type: "text", text: .}] else . end' 2>/dev/null)
                CURRENT_CONTENT=$(jq -cn --argjson a "$CURRENT_CONTENT" --argjson b "$RAW_CONTENT" '$a + $b' 2>/dev/null || echo "$CURRENT_CONTENT")
            fi

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

    _parser_flush_llm_span

    if [ -n "$PARSE_HISTORY_FILE" ]; then
        echo "$CONVERSATION_HISTORY" > "$PARSE_HISTORY_FILE" 2>/dev/null || true
    fi
    return 0
}
