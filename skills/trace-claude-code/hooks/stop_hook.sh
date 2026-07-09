#!/bin/bash
###
# Stop Hook - Finalizes the active user-turn trace.
###

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"
# shellcheck source=turn_trace_common.sh
source "$SCRIPT_DIR/turn_trace_common.sh"

debug "Stop hook triggered"
tracing_enabled || { debug "Tracing disabled"; exit 0; }
check_requirements || exit 0

INPUT=$(cat)
debug "Stop input: $(echo "$INPUT" | jq -c '.' 2>/dev/null | head -c 500)"

echo "$INPUT" | jq -e '.' >/dev/null 2>&1 || { debug "Invalid JSON"; exit 0; }

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
LAST_ASSISTANT=$(echo "$INPUT" | jq -r '.last_assistant_message // empty' 2>/dev/null)
if [ -z "$SESSION_ID" ] && [ -n "$TRANSCRIPT_PATH" ]; then
    SESSION_ID=$(basename "$TRANSCRIPT_PATH" .jsonl)
fi
[ -z "$SESSION_ID" ] && { debug "No session ID"; exit 0; }

parent_update_id() {
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import time; print(int(time.time() * 1000))' 2>/dev/null && return
    fi
    echo 30
}

attach_task_notification_followup() {
    [ "$SKIP_TRACE_REASON" = "task-notification" ] || return 0
    [ -n "$LAST_ASSISTANT" ] || { debug "No task-notification follow-up assistant output"; return 0; }

    local parent_session trace_id project_id root_span_id task_span_id trace_start task_start turn_index notification task_id
    local parent_input_json parent_output_json parent_llm_calls parent_tool_calls parent_workspace parent_workspace_name parent_hostname parent_username parent_os
    IFS=$'\x1f' read -r parent_session trace_id project_id root_span_id task_span_id trace_start task_start turn_index task_id parent_input_json parent_output_json parent_llm_calls parent_tool_calls parent_workspace parent_workspace_name parent_hostname parent_username parent_os \
        <<< "$(get_session_fields "$SESSION_ID" parent_session_id parent_trace_id task_notification_project_id task_notification_root_span_id task_notification_task_span_id task_notification_trace_start task_notification_task_start task_notification_turn_index task_notification_task_id task_notification_task_input_json task_notification_task_output_json task_notification_llm_calls task_notification_tool_calls task_notification_workspace task_notification_workspace_name task_notification_hostname task_notification_username task_notification_os)"
    notification=$(get_session_state "$SESSION_ID" "task_notification_prompt")

    [ -n "$trace_id" ] && [ -n "$project_id" ] && [ -n "$root_span_id" ] && [ -n "$task_span_id" ] && [ -n "$parent_session" ] || {
        debug "Missing parent trace state for task-notification follow-up"
        return 0
    }

    local transcript_path relay_record request_id request_start_iso request_end_iso relay_start relay_end model usage inp out cc cr usage_meta
    transcript_path=$(find_transcript_path "$SESSION_ID" "$TRANSCRIPT_PATH" || true)
    relay_record=""
    if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
        relay_record=$(jq -c --rawfile out <(printf '%s' "$LAST_ASSISTANT") '
            select(.type == "assistant")
            | ([.message.content[]? | select(.type == "text") | .text] | join("\n")) as $text
            | select($text == $out)
        ' "$transcript_path" 2>/dev/null | tail -1)
    fi

    request_id=$(echo "$relay_record" | jq -r '.requestId // empty' 2>/dev/null)
    request_end_iso=$(echo "$relay_record" | jq -r '.timestamp // empty' 2>/dev/null)
    request_start_iso=""
    if [ -n "$request_id" ] && [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
        # Match parse_turn_transcript: the LLM call starts at the record that
        # precedes the first record of this request (the notification prompt),
        # not at the request's own first record — a single-record response
        # would otherwise collapse to a zero-duration span.
        request_start_iso=$(jq -rs --arg req "$request_id" '
            (map(.requestId // "") | index($req)) as $i
            | if $i == null or $i == 0 then empty
              else (.[0:$i] | map(.timestamp // empty | select(length > 0)) | last) // empty
              end
        ' "$transcript_path" 2>/dev/null)
    fi
    [ -z "$request_start_iso" ] && request_start_iso="$request_end_iso"

    relay_end=$(iso_to_nanos "$request_end_iso")
    relay_start=$(iso_to_nanos "$request_start_iso")
    if [ "$relay_start" -gt "$relay_end" ] 2>/dev/null; then
        relay_start="$relay_end"
    fi

    model=$(echo "$relay_record" | jq -r '.message.model // .model // empty' 2>/dev/null)
    [ -z "$model" ] && model="claude"
    usage=$(echo "$relay_record" | jq -c '.message.usage // .usage // {}' 2>/dev/null)
    [ -z "$usage" ] || [ "$usage" = "null" ] && usage="{}"
    inp=$(echo "$usage" | jq -r '.input_tokens // 0' 2>/dev/null)
    out=$(echo "$usage" | jq -r '.output_tokens // 0' 2>/dev/null)
    cc=$(echo "$usage" | jq -r '.cache_creation_input_tokens // 0' 2>/dev/null)
    cr=$(echo "$usage" | jq -r '.cache_read_input_tokens // 0' 2>/dev/null)
    usage_meta=$(jq -n \
        --argjson inp "${inp:-0}" \
        --argjson out "${out:-0}" \
        --argjson cc "${cc:-0}" \
        --argjson cr "${cr:-0}" \
        '{input_tokens: $inp, output_tokens: $out, cache_creation_input_tokens: $cc, cache_read_input_tokens: $cr}' | jq -c '.')

    local input_payload output_payload input_json output_json span_id attrs span update_id provider messages_json
    messages_json=$(jq -cn \
        --rawfile notification <(printf '%s' "${notification:-Task notification}") \
        --rawfile response <(printf '%s' "$LAST_ASSISTANT") \
        --arg end "$relay_end" \
        '[
          {role: "user", content: [{type: "text", text: $notification}], text: $notification},
          {role: "assistant", timestamp_nanos: $end, content: [{type: "text", text: $response}], text: $response}
        ]')
    input_payload=$(jq -cn \
        --arg session_id "$parent_session" \
        --arg trace_id "$trace_id" \
        --arg root_span_id "$root_span_id" \
        --arg task_span_id "$task_span_id" \
        --argjson turn_index "${turn_index:-1}" \
        --arg workspace "${parent_workspace:-}" \
        --rawfile notification <(printf '%s' "${notification:-Task notification}") \
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
          current_user_prompt: "task-notification",
          messages: [{role: "user", content: [{type: "text", text: $notification}], text: $notification}]
        }')
    output_payload=$(echo "$input_payload" | jq --slurpfile messages_f <(printf '%s\n' "$messages_json") --rawfile response <(printf '%s' "$LAST_ASSISTANT") \
        '.messages = $messages_f[0] | .assistant_output = $response')
    input_json=$(echo "$input_payload" | jq -c '.' | jq -Rs '.')
    output_json=$(echo "$output_payload" | jq -c '.' | jq -Rs '.')
    provider=$(detect_provider "$model")
    update_id=$(parent_update_id)
    span_id=$(generate_span_id)

    attrs=$(build_otlp_attributes "$(jq -n \
        --arg span_kind "llm" \
        --slurpfile input_f <(printf '%s\n' "$input_json") \
        --slurpfile output_f <(printf '%s\n' "$output_json") \
        --arg model "$model" \
        --arg provider "$provider" \
        --argjson prompt "${inp:-0}" \
        --argjson completion "${out:-0}" \
        --argjson cache_create "${cc:-0}" \
        --argjson cache_read "${cr:-0}" \
        --arg usage_meta "$usage_meta" \
        --arg session_id "$parent_session" \
        --argjson turn_index "${turn_index:-1}" \
        '$input_f[0] as $input | $output_f[0] as $output | {
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
    span=$(build_otlp_span "$trace_id" "$span_id" "$task_span_id" "$model" "llm" "$relay_start" "$relay_end" "$attrs" "$update_id")
    insert_span "$project_id" "$span" >/dev/null || debug "Failed to attach task-notification follow-up LLM"

    if [ -n "$parent_input_json" ] && [ -n "$parent_output_json" ] &&
       [ -n "$trace_start" ] && [ -n "$task_start" ] &&
       echo "$parent_input_json" | jq -e 'type == "string"' >/dev/null 2>&1 &&
       echo "$parent_output_json" | jq -e 'type == "string"' >/dev/null 2>&1; then
        local updated_output_json updated_llm_calls parent_end parent_task_attrs parent_task_span parent_root_attrs parent_root_span root_name
        updated_output_json=$(echo "$parent_output_json" | jq -r '.' 2>/dev/null | jq -c --rawfile response <(printf '%s' "$LAST_ASSISTANT") --arg end "$relay_end" \
            '.messages += [{role: "assistant", timestamp_nanos: $end, content: [{type: "text", text: $response}], text: $response}]
             | .assistant_output = $response' 2>/dev/null | jq -Rs 'rtrimstr("\n")')
        if [ -z "$updated_output_json" ]; then
            updated_output_json="$parent_output_json"
        fi
        updated_llm_calls=$(( ${parent_llm_calls:-0} + 1 ))
        parent_end="$relay_end"

        parent_task_attrs=$(build_otlp_attributes "$(jq -n \
            --arg span_kind "task" \
            --slurpfile input_f <(printf '%s\n' "$parent_input_json") \
            --slurpfile output_f <(printf '%s\n' "$updated_output_json") \
            --argjson llm "$updated_llm_calls" \
            --argjson tools "${parent_tool_calls:-0}" \
            --arg session_id "$parent_session" \
            --argjson turn_index "${turn_index:-1}" \
            '$input_f[0] as $input | $output_f[0] as $output | {
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
        parent_task_span=$(build_otlp_span "$trace_id" "$task_span_id" "$root_span_id" "Task" "task" "$task_start" "$parent_end" "$parent_task_attrs" "$update_id")
        insert_span "$project_id" "$parent_task_span" >/dev/null || debug "Failed to extend parent task for task-notification follow-up"

        parent_root_attrs=$(build_otlp_attributes "$(jq -n \
            --arg span_kind "task" \
            --slurpfile input_f <(printf '%s\n' "$parent_input_json") \
            --slurpfile output_f <(printf '%s\n' "$updated_output_json") \
            --arg session_id "$parent_session" \
            --arg workspace "${parent_workspace:-}" \
            --arg hostname "${parent_hostname:-$(get_hostname)}" \
            --arg username "${parent_username:-$(get_username)}" \
            --arg os "${parent_os:-$(get_os)}" \
            --argjson turn_index "${turn_index:-1}" \
            '$input_f[0] as $input | $output_f[0] as $output | {
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
        root_name="Claude Code Turn: ${parent_workspace_name:-Claude Code}"
        parent_root_span=$(build_otlp_span "$trace_id" "$root_span_id" "" "$root_name" "task" "$trace_start" "$parent_end" "$parent_root_attrs" "$update_id")
        insert_span "$project_id" "$parent_root_span" >/dev/null || debug "Failed to extend parent root for task-notification follow-up"

        if [ -n "$task_id" ]; then
            set_session_state_batch "subagent:$task_id" \
                "parent_trace_end" "$parent_end" \
                "parent_task_output_json" "$updated_output_json" \
                "parent_llm_calls" "$updated_llm_calls"
        fi
    fi

    log "INFO" "Task-notification follow-up attached: trace=$trace_id session=$parent_session"
}

SKIP_TRACE_REASON=$(get_session_state "$SESSION_ID" "skip_trace_reason")
if [ -n "$SKIP_TRACE_REASON" ]; then
    debug "Skipping Stop hook for session $SESSION_ID: $SKIP_TRACE_REASON"
    attach_task_notification_followup
    clear_session_keys "$SESSION_ID" \
        skip_trace_reason parent_session_id parent_trace_id \
        task_notification_project_id task_notification_root_span_id task_notification_task_span_id \
        task_notification_trace_start task_notification_task_start task_notification_turn_index \
        task_notification_prompt task_notification_task_id task_notification_task_input_json \
        task_notification_task_output_json task_notification_llm_calls task_notification_tool_calls \
        task_notification_workspace task_notification_workspace_name task_notification_hostname \
        task_notification_username task_notification_os
    exit 0
fi

IFS=$'\x1f' read -r TRACE_ID PROJECT_ID ROOT_SPAN_ID TASK_SPAN_ID TRACE_START TASK_START PROMPT OFFSET TURN_INDEX WORKSPACE STATE_TRANSCRIPT \
    <<< "$(get_session_fields "$SESSION_ID" active_trace_id project_id active_root_span_id active_task_span_id active_trace_start active_task_start active_prompt active_transcript_offset turn_count workspace transcript_path)"

[ -z "$TRACE_ID" ] && { debug "No active turn trace"; exit 0; }
[ -z "$PROJECT_ID" ] || [ -z "$ROOT_SPAN_ID" ] || [ -z "$TASK_SPAN_ID" ] && { debug "Missing active trace state"; exit 0; }

TRANSCRIPT_PATH=$(find_transcript_path "$SESSION_ID" "${TRANSCRIPT_PATH:-$STATE_TRANSCRIPT}" || true)
WORKSPACE_NAME=$(basename "$WORKSPACE" 2>/dev/null || echo "Claude Code")

TURN_TRACE_ID="$TRACE_ID"
TURN_PROJECT_ID="$PROJECT_ID"
TURN_ROOT_SPAN_ID="$ROOT_SPAN_ID"
TURN_TASK_SPAN_ID="$TASK_SPAN_ID"
TURN_TRACE_START="$TRACE_START"
TURN_TASK_START="$TASK_START"
TURN_SESSION_ID="$SESSION_ID"
TURN_PROMPT="$PROMPT"
TURN_OFFSET="${OFFSET:-0}"
TURN_INDEX="${TURN_INDEX:-1}"
TURN_WORKSPACE="$WORKSPACE"
TURN_WORKSPACE_NAME="$WORKSPACE_NAME"
TURN_TRANSCRIPT_PATH="$TRANSCRIPT_PATH"
TURN_FALLBACK_OUTPUT="$LAST_ASSISTANT"

finalize_turn_trace

set_session_state_batch "$SESSION_ID" \
    "transcript_offset" "$TURN_NEW_OFFSET" \
    "last_trace_id" "$TRACE_ID" \
    "last_root_span_id" "$ROOT_SPAN_ID"

PARENT_HOSTNAME=$(get_hostname)
PARENT_USERNAME=$(get_username)
PARENT_OS=$(get_os)
while IFS= read -r SUBAGENT_KEY; do
    [ -z "$SUBAGENT_KEY" ] && continue
    set_session_state_batch "$SUBAGENT_KEY" \
        "trace_start" "${TURN_TRACE_START:-$TRACE_START}" \
        "task_start" "${TURN_TASK_START:-$TASK_START}" \
        "parent_trace_end" "${TURN_FINAL_END:-}" \
        "parent_task_input_json" "${TURN_TASK_INPUT_ATTR_JSON:-}" \
        "parent_task_output_json" "${TURN_TASK_OUTPUT_ATTR_JSON:-}" \
        "parent_llm_calls" "${TURN_LLM_CALLS:-0}" \
        "parent_tool_calls" "${TURN_TOOL_CALLS:-0}" \
        "parent_workspace" "${WORKSPACE:-}" \
        "parent_workspace_name" "${WORKSPACE_NAME:-Claude Code}" \
        "parent_hostname" "$PARENT_HOSTNAME" \
        "parent_username" "$PARENT_USERNAME" \
        "parent_os" "$PARENT_OS"
done < <(load_state | jq -r --arg trace "$TRACE_ID" '
    .sessions
    | to_entries[]
    | select(.key | startswith("subagent:"))
    | select(.value.trace_id == $trace)
    | .key
')

clear_session_keys "$SESSION_ID" \
    active_trace_id active_root_span_id active_task_span_id active_trace_start \
    active_task_start active_prompt active_transcript_offset
set_state_value "current_trace_id" ""

exit 0
