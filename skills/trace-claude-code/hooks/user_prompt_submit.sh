#!/bin/bash
###
# UserPromptSubmit Hook - Starts a new turn TRACE for the prompt
#
# One trace per user turn: the trace's root span is the turn itself. The
# session id groups a session's turn-traces, and each turn root links back
# to the previous turn's root (judgment.link.source_*). Any still-open
# previous turn (user interrupt, failed Stop flush) is finalized first.
###

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"
# shellcheck source=transcript_parser.sh
source "$SCRIPT_DIR/transcript_parser.sh"
hook_guard

debug "UserPromptSubmit hook triggered"
tracing_enabled || { debug "Tracing disabled"; exit 0; }
check_requirements || exit 0

INPUT=$(cat)
[ -n "$DEBUG_ON" ] && debug "UserPromptSubmit input: $(echo "$INPUT" | jq -c '.' 2>/dev/null | head -c 500)"

echo "$INPUT" | jq -e '.' >/dev/null 2>&1 || { debug "Invalid JSON"; exit 0; }

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
PROMPT=$(echo "$INPUT" | jq -r '.prompt // empty' 2>/dev/null)
PROMPT_ID=$(echo "$INPUT" | jq -r '.prompt_id // empty' 2>/dev/null)
WORKSPACE=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)

[ -z "$SESSION_ID" ] && { debug "No session ID"; exit 0; }

# Close out a previous turn that never saw its Stop hook, then start ours.
recover_open_turn "$SESSION_ID" "$WORKSPACE" "$TRANSCRIPT_PATH" "[interrupted by user]"

create_turn_trace "$SESSION_ID" "$WORKSPACE" "$PROMPT" "$PROMPT_ID" "$TRANSCRIPT_PATH" || { debug "No turn trace"; exit 0; }

log "INFO" "Turn started: trace=$TRACE_ID (session=$SESSION_ID)"
exit 0
