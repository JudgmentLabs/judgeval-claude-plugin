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

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)
[ -z "$SESSION_ID" ] && SESSION_ID=$(generate_uuid)

PROMPT=$(echo "$INPUT" | jq -r '.prompt // empty' 2>/dev/null || true)
WORKSPACE=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
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
        # Decide whether the parent spans need extending; the heavy payload
        # construction is deferred to the worker via a notification_attach job.
        EXTEND="false"
        PARENT_END="$NOW"
        if [ -n "$PARENT_TASK_INPUT_JSON" ] && [ -n "$PARENT_TASK_OUTPUT_JSON" ] &&
           [ -n "$TRACE_START" ] && [ -n "$TASK_START" ] &&
           echo "$PARENT_TASK_INPUT_JSON" | jq -e 'type == "string"' >/dev/null 2>&1 &&
           echo "$PARENT_TASK_OUTPUT_JSON" | jq -e 'type == "string"' >/dev/null 2>&1; then
            if [ -n "$PARENT_TRACE_END" ] && [ "$PARENT_TRACE_END" -gt "$PARENT_END" ] 2>/dev/null; then
                PARENT_END="$PARENT_TRACE_END"
            fi
            if [ -z "$PARENT_TRACE_END" ] || [ "$PARENT_END" -gt "$PARENT_TRACE_END" ] 2>/dev/null; then
                EXTEND="true"
                set_session_state_batch "$PARENT_KEY" "parent_trace_end" "$PARENT_END"
            fi
        fi
        EVENT=$(jq -cn \
            --arg project_id "${PROJECT_ID:-}" \
            --arg project_name "$PROJECT" \
            --arg trace_id "$TRACE_ID" \
            --arg span_id "$SPAN_ID" \
            --arg root_span_id "${ROOT_SPAN_ID:-}" \
            --arg task_span_id "$TASK_SPAN_ID" \
            --arg now "$NOW" \
            --arg session_id "$PARENT_SESSION_ID" \
            --arg task_id "$TASK_NOTIFICATION_ID" \
            --arg background_session_id "$SESSION_ID" \
            --arg description "${DESCRIPTION:-Subagent task}" \
            --rawfile notification <(printf '%s' "$PROMPT") \
            --arg status "${TASK_STATUS:-completed}" \
            --arg summary "$TASK_SUMMARY" \
            --arg output_file "$OUTPUT_FILE" \
            --rawfile result <(printf '%s' "$TASK_RESULT") \
            --arg turn_index "${TURN_INDEX:-1}" \
            --arg extend_parent "$EXTEND" \
            --arg trace_start "${TRACE_START:-}" \
            --arg task_start "${TASK_START:-}" \
            --arg parent_end "$PARENT_END" \
            --rawfile parent_task_input_json <(printf '%s' "${PARENT_TASK_INPUT_JSON:-}") \
            --rawfile parent_task_output_json <(printf '%s' "${PARENT_TASK_OUTPUT_JSON:-}") \
            --arg parent_llm_calls "${PARENT_LLM_CALLS:-0}" \
            --arg parent_tool_calls "${PARENT_TOOL_CALLS:-0}" \
            --arg workspace "${PARENT_WORKSPACE:-}" \
            --arg workspace_name "${PARENT_WORKSPACE_NAME:-$WORKSPACE_NAME}" \
            --arg hostname "${PARENT_HOSTNAME:-$(get_hostname)}" \
            --arg username "${PARENT_USERNAME:-$(get_username)}" \
            --arg os "${PARENT_OS:-$(get_os)}" \
            '{type: "notification_attach", attempts: 0, project_id: $project_id, project_name: $project_name,
              trace_id: $trace_id, span_id: $span_id, root_span_id: $root_span_id, task_span_id: $task_span_id,
              now: $now, session_id: $session_id, task_id: $task_id, background_session_id: $background_session_id,
              description: $description, notification: $notification, status: $status, summary: $summary,
              output_file: $output_file, result: $result, turn_index: $turn_index, extend_parent: $extend_parent,
              trace_start: $trace_start, task_start: $task_start, parent_end: $parent_end,
              parent_task_input_json: $parent_task_input_json, parent_task_output_json: $parent_task_output_json,
              parent_llm_calls: $parent_llm_calls, parent_tool_calls: $parent_tool_calls,
              workspace: $workspace, workspace_name: $workspace_name,
              hostname: $hostname, username: $username, os: $os}' 2>/dev/null || true)
        [ -n "$EVENT" ] && enqueue_payload "$PARENT_SESSION_ID" "$EVENT"
        log "INFO" "Queued subagent task notification attach: task=$TASK_NOTIFICATION_ID trace=$TRACE_ID session=$PARENT_SESSION_ID"
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

TRANSCRIPT_PATH=$(find_transcript_path "$SESSION_ID" "$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || true)" || true)
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
              transcript_path: $transcript_path}' 2>/dev/null || true)
        if [ -n "$JOB" ]; then
            enqueue_payload "$SESSION_ID" "$JOB"
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
# Defer all payload building and upload to the background worker: enqueue
# one raw turn_start event carrying the primitives.
EVENT=$(jq -cn \
    --arg project_id "${PROJECT_ID:-}" \
    --arg project_name "$PROJECT" \
    --arg session_id "$SESSION_ID" \
    --arg trace_id "$TRACE_ID" \
    --arg root_span_id "$ROOT_SPAN_ID" \
    --arg task_span_id "$TASK_SPAN_ID" \
    --arg start_time "$START_TIME" \
    --rawfile prompt <(printf '%s' "$PROMPT") \
    --arg workspace "$WORKSPACE" \
    --arg workspace_name "$WORKSPACE_NAME" \
    --arg hostname "$(get_hostname)" \
    --arg username "$(get_username)" \
    --arg os "$(get_os)" \
    --arg turn_index "$TURN_INDEX" \
    '{type: "turn_start", attempts: 0, project_id: $project_id, project_name: $project_name,
      session_id: $session_id, trace_id: $trace_id, root_span_id: $root_span_id,
      task_span_id: $task_span_id, start_time: $start_time, prompt: $prompt,
      workspace: $workspace, workspace_name: $workspace_name,
      hostname: $hostname, username: $username, os: $os, turn_index: $turn_index}' 2>/dev/null || true)
[ -n "$EVENT" ] && enqueue_payload "$SESSION_ID" "$EVENT"

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
