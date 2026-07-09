#!/bin/bash
###
# SessionEnd Hook - Fallback finalizer for an open turn trace.
###

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"
# shellcheck source=turn_trace_common.sh
source "$SCRIPT_DIR/turn_trace_common.sh"

debug "SessionEnd hook triggered"
tracing_enabled || { debug "Tracing disabled"; exit 0; }
check_requirements || exit 0

INPUT=$(cat)
debug "SessionEnd input: $(echo "$INPUT" | jq -c '.' 2>/dev/null | head -c 500)"

echo "$INPUT" | jq -e '.' >/dev/null 2>&1 || { debug "Invalid JSON"; exit 0; }

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
[ -z "$SESSION_ID" ] && { debug "No session ID"; exit 0; }

IFS=$'\x1f' read -r TRACE_ID PROJECT_ID ROOT_SPAN_ID TASK_SPAN_ID TRACE_START TASK_START PROMPT OFFSET TURN_INDEX WORKSPACE STATE_TRANSCRIPT \
    <<< "$(get_session_fields "$SESSION_ID" active_trace_id project_id active_root_span_id active_task_span_id active_trace_start active_task_start active_prompt active_transcript_offset turn_count workspace transcript_path)"

if [ -z "$TRACE_ID" ]; then
    debug "No active turn trace at session end"
    set_state_value "current_trace_id" ""
    exit 0
fi

[ -z "$PROJECT_ID" ] || [ -z "$ROOT_SPAN_ID" ] || [ -z "$TASK_SPAN_ID" ] && { debug "Missing active trace state"; exit 0; }

TRANSCRIPT_PATH=$(find_transcript_path "$SESSION_ID" "$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)" || true)
[ -z "$TRANSCRIPT_PATH" ] && TRANSCRIPT_PATH="$STATE_TRANSCRIPT"
[ -z "$WORKSPACE" ] && WORKSPACE=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
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
TURN_FALLBACK_OUTPUT="Completed"

finalize_turn_trace

set_session_state_batch "$SESSION_ID" \
    "transcript_offset" "$TURN_NEW_OFFSET" \
    "last_trace_id" "$TRACE_ID" \
    "last_root_span_id" "$ROOT_SPAN_ID"

clear_session_keys "$SESSION_ID" \
    active_trace_id active_root_span_id active_task_span_id active_trace_start \
    active_task_start active_prompt active_transcript_offset
set_state_value "current_trace_id" ""

exit 0
