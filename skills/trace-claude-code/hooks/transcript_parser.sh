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
#   PARSE_PROMPT_ID          optional turn prompt id: rows carrying a
#                            different promptId are skipped (transcript
#                            lines are not strictly ordered across turns)
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
# kind ts promptId model input_tokens output_tokens cache_create cache_read payload
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
| ($m.promptId // "") as $pid
| if ($m | type) != "object" or ($m.type // "") == "" then
    ["s", "0", "", "", "0", "0", "0", "0", "{}"]
  elif ($m.isSidechain == true and $skip_side == "1") then
    ["s", "0", "", "", "0", "0", "0", "0", "{}"]
  elif $m.type == "assistant" then
    ($m.message.content // []) as $rc
    | (if ($rc | type) == "string" then [{type: "text", text: $rc}]
       elif ($rc | type) == "array" then $rc else [] end) as $c
    | ($m.message.usage // $m.usage // {}) as $u
    | ["a", $ts, $pid,
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
        | ["t", $ts, $pid, "", "0", "0", "0", "0",
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
        | ["u", $ts, $pid, "", "0", "0", "0", "0", ({txt: $txt} | tojson)]
      end
  else ["s", $ts, $pid, "", "0", "0", "0", "0", "{}"]
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
    [ "$span_end" -lt "$span_start" ] 2>/dev/null && span_end="$span_start"
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
    [ "$5" -lt "$4" ] 2>/dev/null && set -- "$1" "$2" "$3" "$4" "$4"
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

    local KIND TS PID MODEL INP OUT CC CR PAYLOAD
    while IFS="$US" read -r KIND TS PID MODEL INP OUT CC CR PAYLOAD; do
        PARSE_NEW_OFFSET=$((PARSE_NEW_OFFSET + 1))
        [ "$KIND" = "s" ] || [ -z "$KIND" ] && continue
        # Transcript lines are not strictly ordered across turn boundaries:
        # a previous turn's trailing lines can be flushed to the file after
        # the next turn starts. Attribute by promptId, not file position —
        # rows from other turns are skipped (their offset is still consumed;
        # they were either already parsed or belong to a finalized turn).
        if [ -n "$PARSE_PROMPT_ID" ] && [ -n "$PID" ] && [ "$PID" != "$PARSE_PROMPT_ID" ]; then
            continue
        fi
        # Turn window comes only from rows that belong to this parse
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

# finalize_turn_root SESSION_ID WORKSPACE FALLBACK_OUTPUT
# Re-inserts the current turn's ROOT span with transcript-derived window,
# the turn's prompt as input, output, and counts. Reads turn identity from
# the PARSE_* globals' companions (set by the caller): FIN_ROOT_SPAN_ID,
# FIN_TURN_INPUT, FIN_TURN_STARTED, FIN_LINK_ATTRS. Appends to SPAN_BATCH.
finalize_turn_root() {
    local session_id="$1" workspace="$2" fallback_output="$3"
    local t_end t_start t_out t_in extra link attrs span
    t_end="${PARSE_LAST_TS_NANOS:-$(get_time_nanos)}"
    t_start="${PARSE_FIRST_TS_NANOS:-${FIN_TURN_STARTED:-$t_end}}"
    [ "$t_end" -lt "$t_start" ] 2>/dev/null && t_end="$t_start"
    t_out="${PARSE_LAST_OUTPUT:-${fallback_output:-Completed}}"
    t_in="${FIN_TURN_INPUT:-$PARSE_FIRST_USER_INPUT}"
    link="${FIN_LINK_ATTRS}"
    [ -z "$link" ] && link="{}"
    extra=$(jq -cn --argjson llm "$PARSE_LLM_CALLS" --argjson tools "$PARSE_TOOL_CALLS" \
        --argjson link "$link" \
        '{llm_call_count: $llm, tool_count: $tools} + $link')
    attrs=$(build_root_span_attrs "$session_id" "$workspace" "$t_in" "$t_out" "$extra")
    span=$(build_otlp_span "$PARSE_TRACE_ID" "$FIN_ROOT_SPAN_ID" "" "Claude Code: $(workspace_display_name "$workspace")" "task" "$t_start" "$t_end" "$attrs" 20)
    SPAN_BATCH+=("$span")
    return 0
}

# recover_open_turn SESSION_ID WORKSPACE TRANSCRIPT_PATH LABEL
# Finalizes a turn whose Stop hook never ran (user interrupt, crash) or
# whose flush failed: parses its transcript rows (promptId-filtered) under
# its own trace root, closes the root, and advances state on success.
# No-op when the session has no open turn.
recover_open_turn() {
    local session_id="$1" workspace="$2" transcript_path="$3" label="${4:-[interrupted by user]}"
    local o_tid o_rid o_pid o_input o_started o_proj o_off
    IFS=$'\x1f' read -r o_tid o_rid o_pid o_input o_started o_proj o_off \
        <<< "$(get_session_fields "$session_id" trace_id root_span_id current_prompt_id current_turn_input turn_started project_id transcript_offset)"
    [ -z "$o_tid" ] && return 0

    local pfile="$transcript_path"
    [ -z "$pfile" ] || [ ! -f "$pfile" ] && \
        pfile=$(find "$HOME/.claude/projects" -name "${session_id}.jsonl" -type f 2>/dev/null | head -1)

    PARSE_FILE="$pfile"
    PARSE_OFFSET="${o_off:-0}"
    PARSE_TRACE_ID="$o_tid"
    PARSE_PROJECT_ID="$o_proj"
    PARSE_SESSION_ID="$session_id"
    PARSE_PARENT_SPAN_ID="$o_rid"
    PARSE_PROMPT_ID="$o_pid"
    PARSE_HISTORY_FILE=$(session_history_file "$session_id")
    parse_transcript_chunk
    PARSE_PROMPT_ID=""

    FIN_ROOT_SPAN_ID="$o_rid"
    FIN_TURN_INPUT="$o_input"
    FIN_TURN_STARTED="$o_started"
    FIN_LINK_ATTRS=$(previous_trace_link_attrs "$session_id")
    finalize_turn_root "$session_id" "$workspace" "$label"
    if flush_span_batch "$o_proj"; then
        set_session_state_batch "$session_id" "transcript_offset" "$PARSE_NEW_OFFSET"
        record_completed_trace "$session_id" "$o_tid" "$o_rid"
        clear_session_keys "$session_id" trace_id root_span_id current_prompt_id current_turn_input turn_started
        save_parse_history
        log "INFO" "Recovered open turn: $PARSE_LLM_CALLS llm, $PARSE_TOOL_CALLS tool spans (session=$session_id)"
    else
        log "ERROR" "Open-turn recovery spans not delivered; will retry (session=$session_id)"
    fi
    return 0
}
