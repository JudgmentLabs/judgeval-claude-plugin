#!/bin/bash
###
# Stop Hook - Finalizes the turn that just ended
#
# Parses the transcript lines added since the last processed offset,
# creating LLM/tool spans under this turn's Task span, then finalizes the
# Task span with real duration, output, and counts. This makes traces fill
# in live per turn instead of all-at-once at SessionEnd, attributes spans
# to the correct turn, and bounds data loss if the session is killed.
###

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"
# shellcheck source=transcript_parser.sh
source "$SCRIPT_DIR/transcript_parser.sh"

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

TRACE_ID=$(get_session_state "$SESSION_ID" "trace_id")
[ -z "$TRACE_ID" ] && { debug "No current trace"; exit 0; }

PROJECT_ID=$(get_session_state "$SESSION_ID" "project_id")
ROOT_SPAN_ID=$(get_session_state "$SESSION_ID" "root_span_id")
TASK_SPAN_ID=$(get_session_state "$SESSION_ID" "current_task_span_id")
TASK_START=$(get_session_state "$SESSION_ID" "current_task_start")
TASK_INPUT=$(get_session_state "$SESSION_ID" "current_task_input")
OFFSET=$(get_session_state "$SESSION_ID" "transcript_offset")

[ -z "$PROJECT_ID" ] || [ -z "$ROOT_SPAN_ID" ] && { debug "Missing trace state"; exit 0; }
[ -z "$TASK_SPAN_ID" ] && { debug "No open task span"; exit 0; }

[ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ] && \
    TRANSCRIPT_PATH=$(find "$HOME/.claude/projects" -name "${SESSION_ID}.jsonl" -type f 2>/dev/null | head -1)

PARSE_FILE="$TRANSCRIPT_PATH"
PARSE_OFFSET="${OFFSET:-0}"
PARSE_TRACE_ID="$TRACE_ID"
PARSE_PROJECT_ID="$PROJECT_ID"
PARSE_PARENT_SPAN_ID="$TASK_SPAN_ID"
PARSE_HISTORY_FILE=$(session_history_file "$SESSION_ID")
parse_transcript_chunk

TASK_END="${PARSE_LAST_TS_NANOS:-$(get_time_nanos)}"
TASK_START="${TASK_START:-$TASK_END}"
# Child llm/tool spans use transcript timestamps, which can precede the
# hook-recorded task start; widen the task window so children stay inside it.
if [ -n "$PARSE_FIRST_TS_NANOS" ] && [ "$PARSE_FIRST_TS_NANOS" -lt "$TASK_START" ] 2>/dev/null; then
    TASK_START="$PARSE_FIRST_TS_NANOS"
fi
TASK_OUTPUT="${LAST_ASSISTANT:-${PARSE_LAST_OUTPUT:-Completed}}"
TASK_INPUT="${TASK_INPUT:-${PARSE_FIRST_USER_INPUT:-}}"

TASK_INPUT_JSON=$(echo "$TASK_INPUT" | jq -Rs '.')
TASK_ATTRS=$(build_otlp_attributes "$(jq -n \
    --arg span_kind "task" \
    --argjson input "$TASK_INPUT_JSON" \
    --arg output "$TASK_OUTPUT" \
    --argjson llm "$PARSE_LLM_CALLS" \
    --argjson tools "$PARSE_TOOL_CALLS" \
    --arg session_id "$SESSION_ID" \
    '{"judgment.span_kind": $span_kind, "judgment.input": $input, "judgment.output": $output, "llm_call_count": $llm, "tool_count": $tools, "session_id": $session_id}')")
TASK_SPAN=$(build_otlp_span "$TRACE_ID" "$TASK_SPAN_ID" "$ROOT_SPAN_ID" "Task" "task" "$TASK_START" "$TASK_END" "$TASK_ATTRS" 20)
insert_span "$PROJECT_ID" "$TASK_SPAN" >/dev/null || debug "Failed to finalize task"

set_session_state_batch "$SESSION_ID" \
    "transcript_offset" "$PARSE_NEW_OFFSET" \
    "current_task_span_id" "" \
    "current_task_start" "" \
    "current_task_input" ""

log "INFO" "Turn finalized: $PARSE_LLM_CALLS llm, $PARSE_TOOL_CALLS tool spans (session=$SESSION_ID)"
exit 0
