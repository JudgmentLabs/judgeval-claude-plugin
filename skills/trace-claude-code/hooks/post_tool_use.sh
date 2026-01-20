#!/bin/bash
###
# PostToolUse Hook - Tracks tool usage count
###

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

debug "PostToolUse hook triggered"
tracing_enabled || { debug "Tracing disabled"; exit 0; }

INPUT=$(cat)
debug "PostToolUse input: $(echo "$INPUT" | jq -c '.' 2>/dev/null | head -c 500)"

echo "$INPUT" | jq -e '.' >/dev/null 2>&1 || { debug "Invalid JSON"; exit 0; }

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)

[ -z "$TOOL_NAME" ] || [ -z "$SESSION_ID" ] && { debug "No tool/session"; exit 0; }

TOOL_COUNT=$(get_session_state "$SESSION_ID" "current_turn_tool_count")
TOOL_COUNT=$((${TOOL_COUNT:-0} + 1))
set_session_state "$SESSION_ID" "current_turn_tool_count" "$TOOL_COUNT"

log "INFO" "Tool used: $TOOL_NAME (count=$TOOL_COUNT)"
exit 0
