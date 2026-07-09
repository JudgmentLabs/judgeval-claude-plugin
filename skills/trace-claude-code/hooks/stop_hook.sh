#!/bin/bash
###
# Stop Hook - Finalizes the turn TRACE that just ended
#
# Parses the transcript rows belonging to this turn (attributed by
# promptId — transcript lines are not strictly ordered across turns),
# creates LLM/tool spans under the turn's root span, finalizes the root
# with the turn's real window/output/counts, and ships everything in
# bounded batches. State only advances when delivery succeeds.
###

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"
# shellcheck source=transcript_parser.sh
source "$SCRIPT_DIR/transcript_parser.sh"
hook_guard

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

IFS=$'\x1f' read -r TRACE_ID ROOT_SPAN_ID PROJECT_ID PROMPT_ID TURN_INPUT TURN_STARTED OFFSET WORKSPACE \
    <<< "$(get_session_fields "$SESSION_ID" trace_id root_span_id project_id current_prompt_id current_turn_input turn_started transcript_offset workspace)"

[ -z "$TRACE_ID" ] && { debug "No open turn"; exit 0; }
[ -z "$PROJECT_ID" ] || [ -z "$ROOT_SPAN_ID" ] && { debug "Missing turn state"; exit 0; }

[ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ] && \
    TRANSCRIPT_PATH=$(find "$HOME/.claude/projects" -name "${SESSION_ID}.jsonl" -type f 2>/dev/null | head -1)

PARSE_FILE="$TRANSCRIPT_PATH"
PARSE_OFFSET="${OFFSET:-0}"
PARSE_TRACE_ID="$TRACE_ID"
PARSE_PROJECT_ID="$PROJECT_ID"
PARSE_SESSION_ID="$SESSION_ID"
PARSE_PARENT_SPAN_ID="$ROOT_SPAN_ID"
PARSE_PROMPT_ID="$PROMPT_ID"
PARSE_HISTORY_FILE=$(session_history_file "$SESSION_ID")
parse_transcript_chunk
PARSE_PROMPT_ID=""

FIN_ROOT_SPAN_ID="$ROOT_SPAN_ID"
FIN_TURN_INPUT="$TURN_INPUT"
FIN_TURN_STARTED="$TURN_STARTED"
FIN_LINK_ATTRS=$(previous_trace_link_attrs "$SESSION_ID")
finalize_turn_root "$SESSION_ID" "$WORKSPACE" "$LAST_ASSISTANT"

if flush_span_batch "$PROJECT_ID"; then
    # Only advance past these transcript rows once delivered; on failure
    # the open turn stays claimed and the next prompt (or SessionEnd)
    # retries it with correct attribution instead of silently dropping it.
    set_session_state_batch "$SESSION_ID" "transcript_offset" "$PARSE_NEW_OFFSET"
    record_completed_trace "$SESSION_ID" "$TRACE_ID" "$ROOT_SPAN_ID"
    clear_session_keys "$SESSION_ID" trace_id root_span_id current_prompt_id current_turn_input turn_started
    save_parse_history
    log "INFO" "Turn finalized: $PARSE_LLM_CALLS llm, $PARSE_TOOL_CALLS tool spans (trace=$TRACE_ID)"
else
    log "ERROR" "Turn spans not delivered; will retry from offset $PARSE_OFFSET (session=$SESSION_ID)"
fi
exit 0
