#!/bin/bash
###
# SessionEnd Hook - Fallback finalizer for an open turn trace.
###

set -e
trap 'exit 0' ERR
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

debug "SessionEnd hook triggered"
tracing_enabled || { debug "Tracing disabled"; exit 0; }
check_requirements || exit 0

INPUT=$(cat)
debug "SessionEnd input: $(echo "$INPUT" | jq -c '.' 2>/dev/null | head -c 500)"

echo "$INPUT" | jq -e '.' >/dev/null 2>&1 || { debug "Invalid JSON"; exit 0; }

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)
[ -z "$SESSION_ID" ] && { debug "No session ID"; exit 0; }

IFS=$'\x1f' read -r TRACE_ID PROJECT_ID ROOT_SPAN_ID TASK_SPAN_ID TRACE_START TASK_START PROMPT OFFSET TURN_INDEX WORKSPACE STATE_TRANSCRIPT \
    <<< "$(get_session_fields "$SESSION_ID" active_trace_id project_id active_root_span_id active_task_span_id active_trace_start active_task_start active_prompt active_transcript_offset turn_count workspace transcript_path)"

if [ -z "$TRACE_ID" ]; then
    debug "No active turn trace at session end"
    set_state_value "current_trace_id" ""
    exit 0
fi

[ -z "$ROOT_SPAN_ID" ] || [ -z "$TASK_SPAN_ID" ] && { debug "Missing active trace state"; exit 0; }

TRANSCRIPT_PATH=$(find_transcript_path "$SESSION_ID" "$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || true)" || true)
[ -z "$TRANSCRIPT_PATH" ] && TRANSCRIPT_PATH="$STATE_TRANSCRIPT"
[ -z "$WORKSPACE" ] && WORKSPACE=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
WORKSPACE_NAME=$(basename "$WORKSPACE" 2>/dev/null || echo "Claude Code")

END_COUNT=$(count_file_lines "$TRANSCRIPT_PATH")
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
    --arg transcript_path "${TRANSCRIPT_PATH:-}" \
    '{type: "finalize", session_id: $session_id, trace_id: $trace_id,
      project_id: $project_id, project_name: $project_name,
      root_span_id: $root_span_id, task_span_id: $task_span_id,
      trace_start: $trace_start, task_start: $task_start,
      prompt: $prompt, offset: $offset, end_offset: $end_offset,
      turn_index: $turn_index, workspace: $workspace,
      transcript_path: $transcript_path, last_assistant: "Completed"}' 2>/dev/null || true)
[ -n "$JOB" ] && enqueue_payload "$SESSION_ID" "$JOB"
log "INFO" "Queued session-end finalize: trace=$TRACE_ID session=$SESSION_ID"

set_session_state_batch "$SESSION_ID" \
    "transcript_offset" "$END_COUNT" \
    "last_trace_id" "$TRACE_ID" \
    "last_root_span_id" "$ROOT_SPAN_ID"

clear_session_keys "$SESSION_ID" \
    active_trace_id active_root_span_id active_task_span_id active_trace_start \
    active_task_start active_prompt active_transcript_offset
set_state_value "current_trace_id" ""

# The session is over, so waiting here does not affect the user. Give this
# session's worker a bounded window to flush queued spans for durability.
SDIR=$(session_queue_dir "$SESSION_ID")
DRAIN_DEADLINE=$(( $(date +%s) + 90 ))
while [ -n "$(ls -A "$SDIR/pending" 2>/dev/null)$(ls -A "$SDIR/processing" 2>/dev/null)" ]; do
    [ "$(date +%s)" -ge "$DRAIN_DEADLINE" ] && { log "WARN" "Session end: queue not fully drained"; break; }
    ensure_worker_running "$SESSION_ID"
    sleep 1
done

# Fully drained: removing the pid file is the worker's shutdown signal
# (avoids kill: the pid could have been reused). Then remove the empty
# subtree; a not-quite-drained queue is left for the SessionStart sweep.
if [ -z "$(ls -A "$SDIR/pending" 2>/dev/null)$(ls -A "$SDIR/processing" 2>/dev/null)" ]; then
    rm -f "$SDIR/worker.pid" 2>/dev/null || true
    sleep 1
    rmdir "$SDIR/pending" "$SDIR/processing" "$SDIR" 2>/dev/null || true
fi

exit 0
