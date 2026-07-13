#!/bin/bash
###
# Stop Hook - snapshots the finished turn and queues background finalization.
#
# No parsing, payload building, or network I/O happens here: the hook
# captures the turn boundary and state snapshot, enqueues a finalize job
# (or a relay_attach job for task-notification turns), advances the
# transcript offset, and exits. The background worker does the rest.
###

set -e
trap 'exit 0' ERR
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

debug "Stop hook triggered"
tracing_enabled || { debug "Tracing disabled"; exit 0; }
check_requirements || exit 0

INPUT=$(cat)
debug "Stop input: $(echo "$INPUT" | jq -c '.' 2>/dev/null | head -c 500)"

echo "$INPUT" | jq -e '.' >/dev/null 2>&1 || { debug "Invalid JSON"; exit 0; }

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || true)
LAST_ASSISTANT=$(echo "$INPUT" | jq -r '.last_assistant_message // empty' 2>/dev/null || true)
if [ -z "$SESSION_ID" ] && [ -n "$TRANSCRIPT_PATH" ]; then
    SESSION_ID=$(basename "$TRANSCRIPT_PATH" .jsonl)
fi
[ -z "$SESSION_ID" ] && { debug "No session ID"; exit 0; }

SKIP_TRACE_REASON=$(get_session_state "$SESSION_ID" "skip_trace_reason")
if [ -n "$SKIP_TRACE_REASON" ]; then
    debug "Skipping Stop hook for session $SESSION_ID: $SKIP_TRACE_REASON"

    if [ "$SKIP_TRACE_REASON" = "task-notification" ] && [ -n "$LAST_ASSISTANT" ]; then
        IFS=$'\x1f' read -r parent_session trace_id project_id root_span_id task_span_id trace_start task_start turn_index task_id parent_blob_ref parent_llm_calls parent_tool_calls parent_workspace parent_workspace_name parent_hostname parent_username parent_os \
            <<< "$(get_session_fields "$SESSION_ID" parent_session_id parent_trace_id task_notification_project_id task_notification_root_span_id task_notification_task_span_id task_notification_trace_start task_notification_task_start task_notification_turn_index task_notification_task_id task_notification_blob_ref task_notification_llm_calls task_notification_tool_calls task_notification_workspace task_notification_workspace_name task_notification_hostname task_notification_username task_notification_os)"
        notification=$(get_session_state "$SESSION_ID" "task_notification_prompt")

        if [ -n "$trace_id" ] && [ -n "$root_span_id" ] && [ -n "$task_span_id" ] && [ -n "$parent_session" ]; then
            RELAY_TRANSCRIPT=$(find_transcript_path "$SESSION_ID" "$TRANSCRIPT_PATH" || true)
            EVENT=$(jq -cn \
                --arg session_id "$SESSION_ID" \
                --arg parent_session_id "$parent_session" \
                --arg trace_id "$trace_id" \
                --arg project_id "${project_id:-}" \
                --arg project_name "$PROJECT" \
                --arg root_span_id "$root_span_id" \
                --arg task_span_id "$task_span_id" \
                --arg trace_start "${trace_start:-}" \
                --arg task_start "${task_start:-}" \
                --arg turn_index "${turn_index:-1}" \
                --arg task_id "${task_id:-}" \
                --rawfile notification <(printf '%s' "${notification:-Task notification}") \
                --rawfile last_assistant <(printf '%s' "$LAST_ASSISTANT") \
                --arg parent_blob_ref "${parent_blob_ref:-}" \
                --arg parent_llm_calls "${parent_llm_calls:-0}" \
                --arg parent_tool_calls "${parent_tool_calls:-0}" \
                --arg workspace "${parent_workspace:-}" \
                --arg workspace_name "${parent_workspace_name:-Claude Code}" \
                --arg hostname "${parent_hostname:-$(get_hostname)}" \
                --arg username "${parent_username:-$(get_username)}" \
                --arg os "${parent_os:-$(get_os)}" \
                --arg transcript_path "${RELAY_TRANSCRIPT:-}" \
                '{type: "relay_attach", attempts: 0, session_id: $session_id,
                  parent_session_id: $parent_session_id, trace_id: $trace_id,
                  project_id: $project_id, project_name: $project_name,
                  root_span_id: $root_span_id, task_span_id: $task_span_id,
                  trace_start: $trace_start, task_start: $task_start,
                  turn_index: $turn_index, task_id: $task_id,
                  notification: $notification, last_assistant: $last_assistant,
                  parent_blob_ref: $parent_blob_ref,
                  parent_llm_calls: $parent_llm_calls, parent_tool_calls: $parent_tool_calls,
                  workspace: $workspace, workspace_name: $workspace_name,
                  hostname: $hostname, username: $username, os: $os,
                  transcript_path: $transcript_path}' 2>/dev/null || true)
            [ -n "$EVENT" ] && enqueue_payload "$EVENT"
            log "INFO" "Queued task-notification follow-up attach: trace=$trace_id session=$parent_session"
        else
            debug "Missing parent trace state for task-notification follow-up"
        fi
    fi

    # Advance the offset past the notification and relay records; they are
    # attached to the parent trace, and the next interactive turn must not
    # re-parse them into its own trace as duplicate LLM spans.
    SKIP_TRANSCRIPT=$(find_transcript_path "$SESSION_ID" "$TRANSCRIPT_PATH" || true)
    if [ -n "$SKIP_TRANSCRIPT" ] && [ -f "$SKIP_TRANSCRIPT" ]; then
        set_session_state_batch "$SESSION_ID" \
            "transcript_offset" "$(count_file_lines "$SKIP_TRANSCRIPT")"
    fi
    clear_session_keys "$SESSION_ID" \
        skip_trace_reason parent_session_id parent_trace_id \
        task_notification_project_id task_notification_root_span_id task_notification_task_span_id \
        task_notification_trace_start task_notification_task_start task_notification_turn_index \
        task_notification_prompt task_notification_task_id task_notification_blob_ref \
        task_notification_llm_calls task_notification_tool_calls \
        task_notification_workspace task_notification_workspace_name task_notification_hostname \
        task_notification_username task_notification_os
    exit 0
fi

IFS=$'\x1f' read -r TRACE_ID PROJECT_ID ROOT_SPAN_ID TASK_SPAN_ID TRACE_START TASK_START PROMPT OFFSET TURN_INDEX WORKSPACE STATE_TRANSCRIPT \
    <<< "$(get_session_fields "$SESSION_ID" active_trace_id project_id active_root_span_id active_task_span_id active_trace_start active_task_start active_prompt active_transcript_offset turn_count workspace transcript_path)"

[ -z "$TRACE_ID" ] && { debug "No active turn trace"; exit 0; }
[ -z "$ROOT_SPAN_ID" ] || [ -z "$TASK_SPAN_ID" ] && { debug "Missing active trace state"; exit 0; }

TRANSCRIPT_PATH=$(find_transcript_path "$SESSION_ID" "${TRANSCRIPT_PATH:-$STATE_TRANSCRIPT}" || true)
[ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ] && { debug "No transcript to finalize from"; exit 0; }

END_COUNT=$(count_file_lines_cached "$SESSION_ID" "$TRANSCRIPT_PATH")

JOB=$(jq -cn \
    --arg session_id "$SESSION_ID" \
    --arg trace_id "$TRACE_ID" \
    --arg project_id "${PROJECT_ID:-}" \
    --arg project_name "$PROJECT" \
    --arg root_span_id "$ROOT_SPAN_ID" \
    --arg task_span_id "$TASK_SPAN_ID" \
    --arg trace_start "${TRACE_START:-}" \
    --arg task_start "${TASK_START:-}" \
    --rawfile prompt <(printf '%s' "${PROMPT:-}") \
    --arg offset "${OFFSET:-0}" \
    --arg end_offset "$END_COUNT" \
    --arg turn_index "${TURN_INDEX:-1}" \
    --arg workspace "${WORKSPACE:-}" \
    --arg transcript_path "$TRANSCRIPT_PATH" \
    --rawfile last_assistant <(printf '%s' "${LAST_ASSISTANT:-}") \
    '{type: "finalize", session_id: $session_id, trace_id: $trace_id,
      project_id: $project_id, project_name: $project_name,
      root_span_id: $root_span_id, task_span_id: $task_span_id,
      trace_start: $trace_start, task_start: $task_start,
      prompt: $prompt, offset: $offset, end_offset: $end_offset,
      turn_index: $turn_index, workspace: $workspace,
      transcript_path: $transcript_path, last_assistant: $last_assistant}' 2>/dev/null || true)
[ -n "$JOB" ] && enqueue_payload "$JOB"
log "INFO" "Queued turn finalize: trace=$TRACE_ID session=$SESSION_ID turn=${TURN_INDEX:-1}"

set_session_state_batch "$SESSION_ID" \
    "transcript_offset" "$END_COUNT" \
    "last_trace_id" "$TRACE_ID" \
    "last_root_span_id" "$ROOT_SPAN_ID"

clear_session_keys "$SESSION_ID" \
    active_trace_id active_root_span_id active_task_span_id active_trace_start \
    active_task_start active_prompt active_transcript_offset
set_state_value "current_trace_id" ""

exit 0
