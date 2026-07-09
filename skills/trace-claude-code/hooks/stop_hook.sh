#!/bin/bash
###
# Stop Hook - Finalizes the turn that just ended
#
# Parses the transcript lines added since the last processed offset,
# creating LLM/tool spans under this turn's Task span, then finalizes the
# Task span with transcript-derived duration, output, and counts. All spans
# go out in one batched OTLP request. This makes traces fill in live per
# turn, attributes spans to the correct turn, and bounds data loss if the
# session is killed.
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
[ -n "$DEBUG_ON" ] && debug "Stop input: $(echo "$INPUT" | jq -c '.' 2>/dev/null | head -c 500)"

echo "$INPUT" | jq -e '.' >/dev/null 2>&1 || { debug "Invalid JSON"; exit 0; }

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
LAST_ASSISTANT=$(echo "$INPUT" | jq -r '.last_assistant_message // empty' 2>/dev/null)
if [ -z "$SESSION_ID" ] && [ -n "$TRANSCRIPT_PATH" ]; then
    SESSION_ID=$(basename "$TRANSCRIPT_PATH" .jsonl)
fi
[ -z "$SESSION_ID" ] && { debug "No session ID"; exit 0; }

IFS=$'\x1f' read -r TRACE_ID PROJECT_ID ROOT_SPAN_ID TASK_SPAN_ID OFFSET \
    <<< "$(get_session_fields "$SESSION_ID" trace_id project_id root_span_id current_task_span_id transcript_offset)"

[ -z "$TRACE_ID" ] && { debug "No current trace"; exit 0; }
[ -z "$PROJECT_ID" ] || [ -z "$ROOT_SPAN_ID" ] && { debug "Missing trace state"; exit 0; }
[ -z "$TASK_SPAN_ID" ] && { debug "No open task span"; exit 0; }

[ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ] && \
    TRANSCRIPT_PATH=$(find "$HOME/.claude/projects" -name "${SESSION_ID}.jsonl" -type f 2>/dev/null | head -1)

PARSE_FILE="$TRANSCRIPT_PATH"
PARSE_OFFSET="${OFFSET:-0}"
PARSE_TRACE_ID="$TRACE_ID"
PARSE_PROJECT_ID="$PROJECT_ID"
PARSE_SESSION_ID="$SESSION_ID"
PARSE_PARENT_SPAN_ID="$TASK_SPAN_ID"
PARSE_HISTORY_FILE=$(session_history_file "$SESSION_ID")
parse_transcript_chunk

finalize_task_span "$TASK_SPAN_ID" "$ROOT_SPAN_ID" "$SESSION_ID" "$LAST_ASSISTANT"
flush_span_batch "$PROJECT_ID" || debug "Failed to send turn spans"

set_session_state_batch "$SESSION_ID" "transcript_offset" "$PARSE_NEW_OFFSET"
clear_session_keys "$SESSION_ID" current_task_span_id

log "INFO" "Turn finalized: $PARSE_LLM_CALLS llm, $PARSE_TOOL_CALLS tool spans (session=$SESSION_ID)"
exit 0
