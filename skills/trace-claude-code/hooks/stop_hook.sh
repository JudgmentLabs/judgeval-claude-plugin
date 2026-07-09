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

SKIP_TRACE_REASON=$(get_session_state "$SESSION_ID" "skip_trace_reason")
if [ -n "$SKIP_TRACE_REASON" ]; then
    debug "Skipping Stop hook for session $SESSION_ID: $SKIP_TRACE_REASON"
    clear_session_keys "$SESSION_ID" skip_trace_reason parent_session_id parent_trace_id
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
