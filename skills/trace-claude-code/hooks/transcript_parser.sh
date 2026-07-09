#!/bin/bash
###
# Shared transcript parser
#
# Converts Claude Code transcript JSONL lines into LLM and tool spans.
# Used incrementally by stop_hook.sh (per turn, from a saved line offset),
# by session_end.sh (final sweep for anything the last turn missed), and by
# subagent_stop.sh (whole subagent transcript, offset 0).
#
# The transcript is preprocessed by a SINGLE jq invocation that classifies
# every line and emits one compact record per line (fields joined by the
# 0x1f unit separator, which cannot appear raw in compact JSON). The bash
# loop then only assembles spans. This keeps subprocess count per turn
# roughly constant instead of ~15 per transcript line, which matters
# because the Stop hook runs synchronously before the user's next turn.
#
# Spans are accumulated into SPAN_BATCH and sent as ONE OTLP request via
# flush_span_batch (callers may append more spans, e.g. the Task span,
# before flushing).
#
# LLM span inputs/outputs preserve the provider message format: assistant
# content is the raw content-block array (text + tool_use), and tool results
# are kept in the conversation history as tool_result user messages. The
# true system prompt and tool definitions are not present in the transcript
# and cannot be captured from hooks. To keep span payloads bounded, stored
# history truncates individual content blocks over 4 KB (marked
# "…[truncated]") and keeps the most recent 40 messages.
#
# Inputs (globals, set by caller):
#   PARSE_FILE               transcript path
#   PARSE_OFFSET             number of lines already processed (default 0)
#   PARSE_TRACE_ID           trace id spans belong to
#   PARSE_PROJECT_ID         project id spans are posted to
#   PARSE_PARENT_SPAN_ID     parent span id for created llm/tool spans
#   PARSE_SESSION_ID         session id stamped on created spans
#   PARSE_HISTORY_FILE       optional path persisting conversation history
#                            across turns (empty = start fresh)
#   PARSE_EXTRA_ATTRS        optional jq object merged into llm/tool span
#                            attributes (e.g. {"subagent_id": "..."})
#   PARSE_INCLUDE_SIDECHAIN  "1" to parse sidechain (subagent) lines; by
#                            default they are skipped because
#                            subagent_stop.sh traces them separately
#
# Outputs (globals):
#   PARSE_LLM_CALLS PARSE_TOOL_CALLS PARSE_NEW_OFFSET
#   PARSE_LAST_OUTPUT PARSE_FIRST_USER_INPUT
#   PARSE_FIRST_TS_NANOS PARSE_LAST_TS_NANOS
#   SPAN_BATCH (array; send with flush_span_batch)
###

US=$'\x1f'

# Classifies one transcript line per input line. Output record fields:
# kind ts model input_tokens output_tokens cache_create cache_read payload
# kind: a=assistant, t=tool_result user message, u=plain user message, s=skip
_PARSER_JQ_PROG='
def tonanos:
  (try
    (capture("^(?<b>[^.]+)(?:\\.(?<f>[0-9]+))?Z$")
     | (((.b + "Z") | fromdateiso8601) * 1000000000)
       + ((((.f // "") + "000000000")[0:9]) | tonumber))
  catch 0);
(fromjson? // {}) as $m
| (($m.timestamp // "") | tonanos | tostring) as $ts
| if ($m | type) != "object" or ($m.type // "") == "" then
    ["s", "0", "", "0", "0", "0", "0", "{}"]
  elif ($m.isSidechain == true and $skip_side == "1") then
    ["s", "0", "", "0", "0", "0", "0", "{}"]
  elif $m.type == "assistant" then
    ($m.message.content // []) as $rc
    | (if ($rc | type) == "string" then [{type: "text", text: $rc}]
       elif ($rc | type) == "array" then $rc else [] end) as $c
    | ($m.message.usage // $m.usage // {}) as $u
    | ["a", $ts,
       ($m.message.model // $m.model // ""),
       (($u.input_tokens // 0) | tostring),
       (($u.output_tokens // 0) | tostring),
       (($u.cache_creation_input_tokens // 0) | tostring),
       (($u.cache_read_input_tokens // 0) | tostring),
       ({c: $c,
         tu: [$c[] | select(.type == "tool_use")
              | {id, name, input: (.input // {})}]} | tojson)]
  elif $m.type == "user" then
    ($m.message.content // null) as $c
    | if ($c | type) == "array" and (($c[0].type // "") == "tool_result") then
        ($m.toolUseResult // null) as $tr
        | ["t", $ts, "", "0", "0", "0", "0",
           ({c: $c,
             r: [$c[] | select(.tool_use_id?)
                 | {id: .tool_use_id,
                    out: (if ($tr | type) == "object" then
                            (if ($tr.type // "") == "text"
                             then ($tr.file.content // $tr.text // "completed")
                             else ($tr | tojson) end)
                          elif $tr != null then ($tr | tostring)
                          else ((.content // "result")
                                | if (type == "string" and test("→"))
                                  then sub("^[^→]*→"; "") else tostring end)
                          end)}]} | tojson)]
      else
        (if ($c | type) == "array"
         then ([$c[] | select(.type == "text") | .text] | join("\n"))
         elif ($c | type) == "string" then $c else "" end) as $txt
        | ["u", $ts, "", "0", "0", "0", "0", ({txt: $txt} | tojson)]
      end
  else ["s", $ts, "", "0", "0", "0", "0", "{}"]
  end
| join("\u001f")'

# Truncation applied to content blocks before they enter the stored history
_HISTORY_TRUNC='map(
    if (.content? and (.content | type) == "string" and (.content | length) > 4096)
    then .content = (.content[0:4096] + "…[truncated]")
    elif (.text? and (.text | type) == "string" and (.text | length) > 4096)
    then .text = (.text[0:4096] + "…[truncated]")
    else . end)'

# Flushes the accumulated assistant response (raw content blocks + usage)
# as an llm span into SPAN_BATCH, and appends it to the conversation history.
_parser_flush_llm_span() {
    [ "$CURRENT_CONTENT" = "[]" ] && [ -z "$CURRENT_MODEL" ] && return 0
    [ "$CURRENT_CONTENT" = "[]" ] && CURRENT_CONTENT='[{"type":"text","text":""}]'

    local span_id span_start span_end input_json attrs span provider text extra
    extra="${PARSE_EXTRA_ATTRS}"
    [ -z "$extra" ] && extra="{}"
    span_id=$(generate_uuid | sed 's/-//g' | head -c 16)
    span_start="${LLM_START_TIME:-$(get_time_nanos)}"
    span_end="${LLM_END_TIME:-$(get_time_nanos)}"
    provider=$(detect_provider "$CURRENT_MODEL")
    input_json=$(printf '%s' "$CONVERSATION_HISTORY" | jq -Rs '.')
    attrs=$(build_otlp_attributes "$(jq -n \
        --argjson input "$input_json" --argjson content "$CURRENT_CONTENT" \
        --arg model "${CURRENT_MODEL:-claude}" --arg provider "$provider" \
        --argjson prompt "$CURRENT_PROMPT_TOKENS" --argjson completion "$CURRENT_COMPLETION_TOKENS" \
        --argjson cache_create "$CURRENT_CACHE_CREATION" --argjson cache_read "$CURRENT_CACHE_READ" \
        --arg session_id "${PARSE_SESSION_ID:-}" \
        --argjson extra "$extra" \
        '{
          "judgment.span_kind": "llm",
          "judgment.input": $input,
          "judgment.output": ([{role: "assistant", content: $content}] | tojson),
          "judgment.llm.provider": $provider,
          "judgment.llm.model": $model,
          "judgment.usage.non_cached_input_tokens": $prompt,
          "judgment.usage.output_tokens": $completion,
          "judgment.usage.cache_creation_input_tokens": $cache_create,
          "judgment.usage.cache_read_input_tokens": $cache_read,
          "judgment.usage.metadata": ({input_tokens: $prompt, output_tokens: $completion,
                                       cache_creation_input_tokens: $cache_create,
                                       cache_read_input_tokens: $cache_read} | tojson),
          "judgment.session_id": $session_id
        } + $extra')")
    span=$(build_otlp_span "$PARSE_TRACE_ID" "$span_id" "$PARSE_PARENT_SPAN_ID" "${CURRENT_MODEL:-anthropic.messages.create}" "llm" "$span_start" "$span_end" "$attrs" 20)
    SPAN_BATCH+=("$span")
    PARSE_LLM_CALLS=$((PARSE_LLM_CALLS + 1))

    text=$(printf '%s' "$CURRENT_CONTENT" | jq -r '[.[] | select(.type == "text") | .text] | join("\n")' 2>/dev/null)
    [ -n "$text" ] && PARSE_LAST_OUTPUT="$text"
    CONVERSATION_HISTORY=$(jq -cn --argjson h "$CONVERSATION_HISTORY" --argjson c "$CURRENT_CONTENT" \
        "\$h + [{role: \"assistant\", content: (\$c | $_HISTORY_TRUNC)}]")
    CURRENT_CONTENT="[]"
    return 0
}

# _parser_add_tool_span NAME INPUT_JSON_STRING OUTPUT_JSON_STRING START END
# (input/output arrive as JSON string literals, kept encoded end to end)
_parser_add_tool_span() {
    local attrs span extra
    extra="${PARSE_EXTRA_ATTRS}"
    [ -z "$extra" ] && extra="{}"
    attrs=$(build_otlp_attributes "$(jq -n \
        --argjson input "$2" --argjson output "$3" --arg tool_name "$1" \
        --arg session_id "${PARSE_SESSION_ID:-}" --argjson extra "$extra" \
        '{"judgment.span_kind": "tool", "judgment.input": $input, "judgment.output": $output,
          "tool_name": $tool_name, "judgment.session_id": $session_id} + $extra')")
    span=$(build_otlp_span "$PARSE_TRACE_ID" "$(generate_uuid | sed 's/-//g' | head -c 16)" "$PARSE_PARENT_SPAN_ID" "$1" "tool" "$4" "$5" "$attrs" 20)
    SPAN_BATCH+=("$span")
    PARSE_TOOL_CALLS=$((PARSE_TOOL_CALLS + 1))
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
    SPAN_BATCH=()

    if [ -z "$PARSE_FILE" ] || [ ! -f "$PARSE_FILE" ]; then
        debug "Parser: no transcript file"
        return 0
    fi

    CURRENT_CONTENT="[]"
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
        CONVERSATION_HISTORY=$(jq -c '.[-40:]' "$PARSE_HISTORY_FILE" 2>/dev/null)
        echo "$CONVERSATION_HISTORY" | jq -e '.' >/dev/null 2>&1 || CONVERSATION_HISTORY="[]"
    fi

    local KIND TS MODEL INP OUT CC CR PAYLOAD
    while IFS="$US" read -r KIND TS MODEL INP OUT CC CR PAYLOAD; do
        PARSE_NEW_OFFSET=$((PARSE_NEW_OFFSET + 1))
        [ "$KIND" = "s" ] || [ -z "$KIND" ] && {
            if [ "$TS" -gt 0 ] 2>/dev/null; then
                [ -z "$PARSE_FIRST_TS_NANOS" ] && PARSE_FIRST_TS_NANOS="$TS"
                PARSE_LAST_TS_NANOS="$TS"
            fi
            continue
        }
        if [ "$TS" -gt 0 ] 2>/dev/null; then
            [ -z "$PARSE_FIRST_TS_NANOS" ] && PARSE_FIRST_TS_NANOS="$TS"
            PARSE_LAST_TS_NANOS="$TS"
        fi

        case "$KIND" in
        a)
            [ "$TS" -gt 0 ] 2>/dev/null && LLM_END_TIME="$TS"
            CURRENT_CONTENT=$(jq -cn --argjson a "$CURRENT_CONTENT" --argjson p "$PAYLOAD" '$a + $p.c' 2>/dev/null || echo "$CURRENT_CONTENT")
            if [[ "$PAYLOAD" == *'"tu":[{'* ]]; then
                PENDING_TOOLS=$(jq -cn --argjson pend "$PENDING_TOOLS" --argjson p "$PAYLOAD" --arg ts "$TS" \
                    'reduce $p.tu[] as $t ($pend; .[$t.id] = {name: $t.name, input: ($t.input | tojson), start: $ts})' 2>/dev/null || echo "$PENDING_TOOLS")
            fi
            [ -n "$MODEL" ] && CURRENT_MODEL="$MODEL"
            # Claude Code repeats the same cumulative usage on every assistant
            # content block within one API call: replace, don't accumulate.
            [ "$INP" -gt 0 ] 2>/dev/null && CURRENT_PROMPT_TOKENS=$INP
            [ "$OUT" -gt 0 ] 2>/dev/null && CURRENT_COMPLETION_TOKENS=$OUT
            [ "$CC" -gt 0 ] 2>/dev/null && CURRENT_CACHE_CREATION=$CC
            [ "$CR" -gt 0 ] 2>/dev/null && CURRENT_CACHE_READ=$CR
            ;;
        t)
            _parser_flush_llm_span
            # Keep the tool results in the recorded context window, exactly
            # as they went back to the model (modulo the size cap).
            CONVERSATION_HISTORY=$(jq -cn --argjson h "$CONVERSATION_HISTORY" --argjson p "$PAYLOAD" \
                "\$h + [{role: \"user\", content: (\$p.c | $_HISTORY_TRUNC)}]" 2>/dev/null || echo "$CONVERSATION_HISTORY")
            LLM_START_TIME="$TS"
            if [[ "$PAYLOAD" == *'"r":[{'* ]]; then
                local RID ROUT PEN P_NAME P_INPUT P_START
                while IFS="$US" read -r RID ROUT; do
                    [ -z "$RID" ] && continue
                    PEN=$(jq -rn --argjson p "$PENDING_TOOLS" --arg id "$RID" \
                        'if $p[$id] then
                           ([$p[$id].name, ($p[$id].input | tojson), $p[$id].start] | join("\u001f")),
                           ($p | del(.[$id]) | tojson)
                         else empty end' 2>/dev/null)
                    [ -z "$PEN" ] && continue
                    IFS="$US" read -r P_NAME P_INPUT P_START <<< "$(head -1 <<< "$PEN")"
                    PENDING_TOOLS=$(tail -1 <<< "$PEN")
                    if [ "$P_START" -gt 0 ] 2>/dev/null && [ "$TS" -gt 0 ] 2>/dev/null; then
                        _parser_add_tool_span "$P_NAME" "$P_INPUT" "$ROUT" "$P_START" "$TS"
                    fi
                done < <(echo "$PAYLOAD" | jq -r '.r[] | [.id, (.out | tojson)] | join("\u001f")' 2>/dev/null)
            fi
            CURRENT_MODEL=""; CURRENT_PROMPT_TOKENS=0; CURRENT_COMPLETION_TOKENS=0; CURRENT_CACHE_CREATION=0; CURRENT_CACHE_READ=0
            ;;
        u)
            _parser_flush_llm_span
            local TXT
            TXT=$(echo "$PAYLOAD" | jq -r '.txt // ""' 2>/dev/null)
            if [ -n "$TXT" ]; then
                CONVERSATION_HISTORY=$(jq -cn --argjson h "$CONVERSATION_HISTORY" --arg c "$TXT" \
                    '$h + [{role: "user", content: (if ($c | length) > 4096 then ($c[0:4096] + "…[truncated]") else $c end)}]' 2>/dev/null || echo "$CONVERSATION_HISTORY")
                [ -z "$PARSE_FIRST_USER_INPUT" ] && PARSE_FIRST_USER_INPUT="$TXT"
            fi
            LLM_START_TIME="$TS"
            CURRENT_MODEL=""; CURRENT_PROMPT_TOKENS=0; CURRENT_COMPLETION_TOKENS=0; CURRENT_CACHE_CREATION=0; CURRENT_CACHE_READ=0
            ;;
        esac
    done < <(tail -n +$(( ${PARSE_OFFSET:-0} + 1 )) "$PARSE_FILE" | jq -R -r --arg skip_side "$([ "${PARSE_INCLUDE_SIDECHAIN:-0}" = "1" ] && echo 0 || echo 1)" "$_PARSER_JQ_PROG")

    _parser_flush_llm_span

    # History is persisted by the caller via save_parse_history AFTER a
    # successful flush — writing it here would double-append these messages
    # when a failed flush is retried from the same offset.
    PARSE_FINAL_HISTORY="$CONVERSATION_HISTORY"
    return 0
}

save_parse_history() {
    [ -n "$PARSE_HISTORY_FILE" ] && echo "$PARSE_FINAL_HISTORY" > "$PARSE_HISTORY_FILE" 2>/dev/null
    return 0
}

# finalize_task_span TASK_SPAN_ID ROOT_SPAN_ID SESSION_ID FALLBACK_OUTPUT
# Re-inserts the turn's Task span with transcript-derived start/end (the
# single time source for all turn-scoped spans), input, output, and counts.
# Appends to SPAN_BATCH; caller flushes.
finalize_task_span() {
    local task_span_id="$1" root_span_id="$2" session_id="$3" fallback_output="$4"
    local task_end task_start task_output attrs span
    task_end="${PARSE_LAST_TS_NANOS:-$(get_time_nanos)}"
    task_start="${PARSE_FIRST_TS_NANOS:-$task_end}"
    task_output="${PARSE_LAST_OUTPUT:-${fallback_output:-Completed}}"
    attrs=$(build_otlp_attributes "$(jq -n \
        --arg input "$PARSE_FIRST_USER_INPUT" \
        --arg output "$task_output" \
        --argjson llm "$PARSE_LLM_CALLS" \
        --argjson tools "$PARSE_TOOL_CALLS" \
        --arg session_id "$session_id" \
        '{"judgment.span_kind": "task", "judgment.input": $input, "judgment.output": $output,
          "llm_call_count": $llm, "tool_count": $tools, "judgment.session_id": $session_id}')")
    span=$(build_otlp_span "$PARSE_TRACE_ID" "$task_span_id" "$root_span_id" "Task" "task" "$task_start" "$task_end" "$attrs" 20)
    SPAN_BATCH+=("$span")
    return 0
}
