#!/bin/bash
###
# UserPromptSubmit Hook - Opens one trace for the user turn.
###

set -e
# Never surface a failure to Claude Code: a nonzero exit (2 especially) can
# block the user's prompt. Tracing must be strictly best-effort.
trap 'exit 0' ERR
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

debug "UserPromptSubmit hook triggered"
tracing_enabled || { debug "Tracing disabled"; exit 0; }
check_requirements || exit 0

INPUT=$(cat)
debug "UserPromptSubmit input: $(echo "$INPUT" | jq -c '.' 2>/dev/null | head -c 500)"

echo "$INPUT" | jq -e '.' >/dev/null 2>&1 || { debug "Invalid JSON"; exit 0; }

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
[ -z "$SESSION_ID" ] && SESSION_ID=$(generate_uuid)

PROMPT=$(echo "$INPUT" | jq -r '.prompt // empty' 2>/dev/null)
WORKSPACE=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
[ -z "$WORKSPACE" ] && WORKSPACE=$(get_session_state "$SESSION_ID" "workspace")
WORKSPACE_NAME=$(basename "$WORKSPACE" 2>/dev/null || echo "Claude Code")

extract_task_notification_tag() {
    local tag="$1"
    sed -n "s:.*<$tag>\\([^<]*\\)</$tag>.*:\\1:p" | head -1
}

extract_task_notification_result() {
    awk '
        /<result>/ {
            in_result = 1
            sub(/^.*<result>/, "")
        }
        /<\/result>/ {
            sub(/<\/result>.*$/, "")
            print
            exit
        }
        in_result { print }
    '
}

TASK_NOTIFICATION_ID=""
if printf '%s\n' "$PROMPT" | grep -q '<task-notification>'; then
    TASK_NOTIFICATION_ID=$(printf '%s\n' "$PROMPT" | extract_task_notification_tag "task-id")
fi

if [ -n "$TASK_NOTIFICATION_ID" ]; then
    PARENT_KEY="subagent:$TASK_NOTIFICATION_ID"
    IFS=$'\x1f' read -r PARENT_SESSION_ID TRACE_ID PROJECT_ID ROOT_SPAN_ID TASK_SPAN_ID TOOL_SPAN_ID TURN_INDEX PARENT_WORKSPACE DESCRIPTION TRACE_START TASK_START PARENT_TRACE_END PARENT_TASK_INPUT_JSON PARENT_TASK_OUTPUT_JSON PARENT_LLM_CALLS PARENT_TOOL_CALLS PARENT_WORKSPACE_NAME PARENT_HOSTNAME PARENT_USERNAME PARENT_OS \
        <<< "$(get_session_fields "$PARENT_KEY" parent_session_id trace_id project_id root_span_id task_span_id tool_span_id turn_index workspace description trace_start task_start parent_trace_end parent_task_input_json parent_task_output_json parent_llm_calls parent_tool_calls parent_workspace_name parent_hostname parent_username parent_os)"

    TASK_STATUS=$(printf '%s\n' "$PROMPT" | extract_task_notification_tag "status")
    TASK_SUMMARY=$(printf '%s\n' "$PROMPT" | extract_task_notification_tag "summary")
    OUTPUT_FILE=$(printf '%s\n' "$PROMPT" | extract_task_notification_tag "output-file")
    TASK_RESULT=$(printf '%s\n' "$PROMPT" | extract_task_notification_result)

    if [ -n "$TRACE_ID" ] && [ -n "$TASK_SPAN_ID" ] && [ -n "$PARENT_SESSION_ID" ]; then
        SPAN_ID=$(generate_span_id)
        NOW=$(get_time_nanos)
        INPUT_JSON=$(jq -cn \
            --arg task_id "$TASK_NOTIFICATION_ID" \
            --arg background_session_id "$SESSION_ID" \
            --arg description "${DESCRIPTION:-Subagent task}" \
            --rawfile notification <(printf '%s' "$PROMPT") \
            '{task_id: $task_id, background_session_id: $background_session_id, description: $description, notification: $notification}' | jq -c '.' | jq -Rs '.')
        OUTPUT_JSON=$(jq -cn \
            --arg status "${TASK_STATUS:-completed}" \
            --arg summary "$TASK_SUMMARY" \
            --arg output_file "$OUTPUT_FILE" \
            --rawfile result <(printf '%s' "$TASK_RESULT") \
            '{status: $status, summary: $summary, output_file: $output_file, result: $result}' | jq -c '.' | jq -Rs '.')
        ATTRS=$(build_otlp_attributes "$(jq -n \
            --arg span_kind "task" \
            --slurpfile input_f <(printf '%s\n' "$INPUT_JSON") \
            --slurpfile output_f <(printf '%s\n' "$OUTPUT_JSON") \
            --arg task_id "$TASK_NOTIFICATION_ID" \
            --arg background_session_id "$SESSION_ID" \
            --arg session_id "$PARENT_SESSION_ID" \
            --argjson turn_index "${TURN_INDEX:-1}" \
            '$input_f[0] as $input | $output_f[0] as $output | {
              "judgment.span_kind": $span_kind,
              "judgment.input": $input,
              "judgment.output": $output,
              "subagent_task_id": $task_id,
              "background_session_id": $background_session_id,
              "judgment.session_id": $session_id,
              "session_id": $session_id,
              "turn_index": $turn_index
            }')"
        )
        SPAN=$(build_otlp_span "$TRACE_ID" "$SPAN_ID" "$TASK_SPAN_ID" "Subagent Result: ${TASK_SUMMARY:-$TASK_NOTIFICATION_ID}" "task" "$NOW" "$NOW" "$ATTRS" 20)
        insert_span "$PROJECT_ID" "$SPAN" >/dev/null || debug "Failed to attach subagent task notification"

        if [ -n "$PARENT_TASK_INPUT_JSON" ] && [ -n "$PARENT_TASK_OUTPUT_JSON" ] &&
           [ -n "$TRACE_START" ] && [ -n "$TASK_START" ] &&
           echo "$PARENT_TASK_INPUT_JSON" | jq -e 'type == "string"' >/dev/null 2>&1 &&
           echo "$PARENT_TASK_OUTPUT_JSON" | jq -e 'type == "string"' >/dev/null 2>&1; then
            PARENT_END="$NOW"
            if [ -n "$PARENT_TRACE_END" ] && [ "$PARENT_TRACE_END" -gt "$PARENT_END" ] 2>/dev/null; then
                PARENT_END="$PARENT_TRACE_END"
            fi
            if [ -z "$PARENT_TRACE_END" ] || [ "$PARENT_END" -gt "$PARENT_TRACE_END" ] 2>/dev/null; then
                if command -v python3 >/dev/null 2>&1; then
                    UPDATE_ID=$(python3 -c 'import time; print(int(time.time() * 1000))' 2>/dev/null || echo 30)
                else
                    UPDATE_ID=30
                fi

                PARENT_TASK_ATTRS=$(build_otlp_attributes "$(jq -n \
                    --arg span_kind "task" \
                    --slurpfile input_f <(printf '%s\n' "$PARENT_TASK_INPUT_JSON") \
                    --slurpfile output_f <(printf '%s\n' "$PARENT_TASK_OUTPUT_JSON") \
                    --argjson llm "${PARENT_LLM_CALLS:-0}" \
                    --argjson tools "${PARENT_TOOL_CALLS:-0}" \
                    --arg session_id "$PARENT_SESSION_ID" \
                    --argjson turn_index "${TURN_INDEX:-1}" \
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
                PARENT_TASK_SPAN=$(build_otlp_span "$TRACE_ID" "$TASK_SPAN_ID" "$ROOT_SPAN_ID" "Task" "task" "$TASK_START" "$PARENT_END" "$PARENT_TASK_ATTRS" "$UPDATE_ID")
                insert_span "$PROJECT_ID" "$PARENT_TASK_SPAN" >/dev/null || debug "Failed to extend parent task span for task notification"

                PARENT_ROOT_ATTRS=$(build_otlp_attributes "$(jq -n \
                    --arg span_kind "task" \
                    --slurpfile input_f <(printf '%s\n' "$PARENT_TASK_INPUT_JSON") \
                    --slurpfile output_f <(printf '%s\n' "$PARENT_TASK_OUTPUT_JSON") \
                    --arg session_id "$PARENT_SESSION_ID" \
                    --arg workspace "${PARENT_WORKSPACE:-}" \
                    --arg hostname "${PARENT_HOSTNAME:-$(get_hostname)}" \
                    --arg username "${PARENT_USERNAME:-$(get_username)}" \
                    --arg os "${PARENT_OS:-$(get_os)}" \
                    --argjson turn_index "${TURN_INDEX:-1}" \
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
                PARENT_ROOT_NAME="Claude Code Turn: ${PARENT_WORKSPACE_NAME:-$WORKSPACE_NAME}"
                PARENT_ROOT_SPAN=$(build_otlp_span "$TRACE_ID" "$ROOT_SPAN_ID" "" "$PARENT_ROOT_NAME" "task" "$TRACE_START" "$PARENT_END" "$PARENT_ROOT_ATTRS" "$UPDATE_ID")
                insert_span "$PROJECT_ID" "$PARENT_ROOT_SPAN" >/dev/null || debug "Failed to extend parent root span for task notification"
                set_session_state_batch "$PARENT_KEY" "parent_trace_end" "$PARENT_END"
            fi
        else
            debug "No stored parent attrs for task notification parent update"
        fi

        log "INFO" "Subagent task notification attached: task=$TASK_NOTIFICATION_ID trace=$TRACE_ID session=$PARENT_SESSION_ID"
    else
        log "WARN" "Skipping orphan task notification without parent trace mapping: task=$TASK_NOTIFICATION_ID session=$SESSION_ID"
    fi

    set_session_state_batch "$SESSION_ID" \
        "skip_trace_reason" "task-notification" \
        "parent_session_id" "${PARENT_SESSION_ID:-}" \
        "parent_trace_id" "${TRACE_ID:-}" \
        "task_notification_project_id" "${PROJECT_ID:-}" \
        "task_notification_root_span_id" "${ROOT_SPAN_ID:-}" \
        "task_notification_task_span_id" "${TASK_SPAN_ID:-}" \
        "task_notification_trace_start" "${TRACE_START:-}" \
        "task_notification_task_start" "${TASK_START:-}" \
        "task_notification_turn_index" "${TURN_INDEX:-1}" \
        "task_notification_prompt" "$PROMPT" \
        "task_notification_task_id" "$TASK_NOTIFICATION_ID" \
        "task_notification_task_input_json" "${PARENT_TASK_INPUT_JSON:-}" \
        "task_notification_task_output_json" "${PARENT_TASK_OUTPUT_JSON:-}" \
        "task_notification_llm_calls" "${PARENT_LLM_CALLS:-0}" \
        "task_notification_tool_calls" "${PARENT_TOOL_CALLS:-0}" \
        "task_notification_workspace" "${PARENT_WORKSPACE:-}" \
        "task_notification_workspace_name" "${PARENT_WORKSPACE_NAME:-$WORKSPACE_NAME}" \
        "task_notification_hostname" "${PARENT_HOSTNAME:-}" \
        "task_notification_username" "${PARENT_USERNAME:-}" \
        "task_notification_os" "${PARENT_OS:-}"
    exit 0
fi

TRANSCRIPT_PATH=$(find_transcript_path "$SESSION_ID" "$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)" || true)
[ -z "$TRANSCRIPT_PATH" ] && TRANSCRIPT_PATH=$(get_session_state "$SESSION_ID" "transcript_path")

# Cached lookup only — hooks never resolve over the network. Empty is fine:
# spans are queued with the project name and the background worker resolves it.
PROJECT_ID=$(get_session_state "$SESSION_ID" "project_id")
[ -z "$PROJECT_ID" ] && PROJECT_ID=$(get_cached_project_id)

OFFSET=$(get_session_state "$SESSION_ID" "transcript_offset")
[ -z "$OFFSET" ] && OFFSET=$(count_file_lines "$TRANSCRIPT_PATH")

# Recover a previous turn whose Stop hook never finalized (e.g. killed at its
# timeout). Snapshot it into a background finalize job, and start this turn
# after the recovered records so they are not re-parsed into this trace.
DANGLING_TRACE_ID=$(get_session_state "$SESSION_ID" "active_trace_id")
if [ -n "$DANGLING_TRACE_ID" ] && [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
    IFS=$'\x1f' read -r D_ROOT D_TASK D_TRACE_START D_TASK_START D_PROMPT D_OFFSET D_TURN \
        <<< "$(get_session_fields "$SESSION_ID" active_root_span_id active_task_span_id active_trace_start active_task_start active_prompt active_transcript_offset turn_count)"
    D_END=$(count_file_lines "$TRANSCRIPT_PATH")
    if [ -n "$D_ROOT" ] && [ -n "$D_TASK" ]; then
        JOB=$(jq -cn \
            --arg session_id "$SESSION_ID" \
            --arg trace_id "$DANGLING_TRACE_ID" \
            --arg project_id "${PROJECT_ID:-}" \
            --arg project_name "$PROJECT" \
            --arg root_span_id "$D_ROOT" \
            --arg task_span_id "$D_TASK" \
            --arg trace_start "$D_TRACE_START" \
            --arg task_start "$D_TASK_START" \
            --rawfile prompt <(printf '%s' "$D_PROMPT") \
            --arg offset "${D_OFFSET:-0}" \
            --arg end_offset "$D_END" \
            --arg turn_index "${D_TURN:-1}" \
            --arg workspace "${WORKSPACE:-}" \
            --arg transcript_path "$TRANSCRIPT_PATH" \
            '{type: "finalize", session_id: $session_id, trace_id: $trace_id,
              project_id: $project_id, project_name: $project_name,
              root_span_id: $root_span_id, task_span_id: $task_span_id,
              trace_start: $trace_start, task_start: $task_start,
              prompt: $prompt, offset: $offset, end_offset: $end_offset,
              turn_index: $turn_index, workspace: $workspace,
              transcript_path: $transcript_path}' 2>/dev/null)
        if [ -n "$JOB" ]; then
            enqueue_payload "$JOB"
            log "INFO" "Queued recovery finalize for unfinalized turn: trace=$DANGLING_TRACE_ID session=$SESSION_ID"
            OFFSET="$D_END"
        fi
    fi
fi

TURN_INDEX=$(get_session_state "$SESSION_ID" "turn_count")
TURN_INDEX=$((${TURN_INDEX:-0} + 1))

TRACE_ID=$(generate_trace_id)
ROOT_SPAN_ID=$(generate_span_id)
TASK_SPAN_ID=$(generate_span_id)
START_TIME=$(get_time_nanos)
PROMPT_JSON=$(echo "$PROMPT" | jq -Rs '.')

ROOT_ATTRS=$(build_otlp_attributes "$(jq -n \
    --arg span_kind "task" \
    --slurpfile input_f <(printf '%s\n' "$PROMPT_JSON") \
    --arg session_id "$SESSION_ID" \
    --arg workspace "$WORKSPACE" \
    --arg hostname "$(get_hostname)" \
    --arg username "$(get_username)" \
    --arg os "$(get_os)" \
    --argjson turn_index "$TURN_INDEX" \
    '$input_f[0] as $input | {
        "judgment.span_kind": $span_kind,
        "judgment.input": $input,
        "judgment.output": "",
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
ROOT_SPAN=$(build_otlp_span "$TRACE_ID" "$ROOT_SPAN_ID" "" "Claude Code Turn: $WORKSPACE_NAME" "task" "$START_TIME" "$START_TIME" "$ROOT_ATTRS" 0)
insert_span_sync "$PROJECT_ID" "$ROOT_SPAN" >/dev/null || { log "ERROR" "Failed to create turn trace root"; exit 0; }

TASK_ATTRS=$(build_otlp_attributes "$(jq -n \
    --arg span_kind "task" \
    --slurpfile input_f <(printf '%s\n' "$PROMPT_JSON") \
    --arg session_id "$SESSION_ID" \
    --argjson turn_index "$TURN_INDEX" \
    '$input_f[0] as $input | {
        "judgment.span_kind": $span_kind,
        "judgment.input": $input,
        "judgment.output": "",
        "judgment.session_id": $session_id,
        "session_id": $session_id,
        "turn_index": $turn_index
    }')"
)
TASK_SPAN=$(build_otlp_span "$TRACE_ID" "$TASK_SPAN_ID" "$ROOT_SPAN_ID" "Task" "task" "$START_TIME" "$START_TIME" "$TASK_ATTRS" 0)
insert_span "$PROJECT_ID" "$TASK_SPAN" >/dev/null || { log "ERROR" "Failed to create task span"; exit 0; }

set_session_state_batch "$SESSION_ID" \
    "project_id" "$PROJECT_ID" \
    "workspace" "${WORKSPACE:-}" \
    "transcript_path" "${TRANSCRIPT_PATH:-}" \
    "turn_count" "$TURN_INDEX" \
    "active_trace_id" "$TRACE_ID" \
    "active_root_span_id" "$ROOT_SPAN_ID" \
    "active_task_span_id" "$TASK_SPAN_ID" \
    "active_trace_start" "$START_TIME" \
    "active_task_start" "$START_TIME" \
    "active_prompt" "$PROMPT" \
    "active_transcript_offset" "${OFFSET:-0}"

set_state_value "current_trace_id" "$TRACE_ID"

log "INFO" "Turn trace started: trace=$TRACE_ID session=$SESSION_ID turn=$TURN_INDEX"
exit 0
