#!/bin/bash
###
# SessionStart Hook - Prepares the session for turn tracing
#
# Turn traces are created at UserPromptSubmit; this hook warms the project
# cache (so the first prompt doesn't pay resolution latency) and finalizes
# any turn left open by a previous process of this session (crash, resume
# with an interrupted turn).
###

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"
# shellcheck source=transcript_parser.sh
source "$SCRIPT_DIR/transcript_parser.sh"
hook_guard

debug "SessionStart hook triggered"
tracing_enabled || { debug "Tracing disabled"; exit 0; }
check_requirements || exit 0

INPUT=$(cat)
[ -n "$DEBUG_ON" ] && debug "SessionStart input: $(echo "$INPUT" | head -c 500)"

echo "$INPUT" | jq -e '.' >/dev/null 2>&1 || { debug "Invalid JSON"; exit 0; }

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
WORKSPACE=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)

[ -z "$SESSION_ID" ] && { debug "No session ID"; exit 0; }

get_project_id "$PROJECT" >/dev/null || log "ERROR" "Failed to resolve project"

recover_open_turn "$SESSION_ID" "$WORKSPACE" "$TRANSCRIPT_PATH" "[interrupted]"

log "INFO" "Session ready: $SESSION_ID"
exit 0
