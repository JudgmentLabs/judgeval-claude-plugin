#!/bin/bash
###
# SessionEnd Hook - Finalizes any open turn and cleans up session state
#
# Turn traces finalize live at each Stop; the only work left here is a
# turn cut short by the session ending (still-open turn state), plus
# housekeeping. The conversation history file is kept so a resumed
# session's LLM spans retain their restored context; stale files age out.
###

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"
# shellcheck source=transcript_parser.sh
source "$SCRIPT_DIR/transcript_parser.sh"
hook_guard

debug "SessionEnd hook triggered"
tracing_enabled || { debug "Tracing disabled"; exit 0; }
check_requirements || exit 0

INPUT=$(cat)
[ -n "$DEBUG_ON" ] && debug "SessionEnd input: $(echo "$INPUT" | jq -c '.' 2>/dev/null | head -c 500)"

echo "$INPUT" | jq -e '.' >/dev/null 2>&1 || { debug "Invalid JSON"; exit 0; }

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
[ -z "$SESSION_ID" ] && { debug "No session ID"; exit 0; }

WORKSPACE=$(get_session_state "$SESSION_ID" "workspace")
[ -z "$WORKSPACE" ] && WORKSPACE=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)

# Last hook for this session: give the open-turn recovery a second chance
# if the first flush fails — a silent failure here leaves that turn
# looking permanently in-progress.
if [ -n "$(get_session_state "$SESSION_ID" "trace_id")" ]; then
    recover_open_turn "$SESSION_ID" "$WORKSPACE" "$TRANSCRIPT_PATH" "[session ended]"
    if [ -n "$(get_session_state "$SESSION_ID" "trace_id")" ]; then
        sleep 1
        recover_open_turn "$SESSION_ID" "$WORKSPACE" "$TRANSCRIPT_PATH" "[session ended]"
        [ -n "$(get_session_state "$SESSION_ID" "trace_id")" ] && \
            log "ERROR" "Open turn not finalized at session end (session=$SESSION_ID)"
    fi
fi

clear_session_state "$SESSION_ID"
find "$HOME/.claude/state" -name 'judgeval_history_*.json' -mtime +7 -delete 2>/dev/null || true

log "INFO" "Session ended: $SESSION_ID"
exit 0
