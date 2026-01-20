#!/bin/bash
###
# SessionStart Hook - Creates root trace span when session begins
###

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

debug "SessionStart hook triggered"
tracing_enabled || { debug "Tracing disabled"; exit 0; }
check_requirements || exit 0

INPUT=$(cat)
debug "SessionStart input: $(echo "$INPUT" | head -c 500)"

echo "$INPUT" | jq -e '.' >/dev/null 2>&1 || { debug "Invalid JSON"; exit 0; }

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
[ -z "$SESSION_ID" ] && SESSION_ID=$(generate_uuid)

PROJECT_ID=$(get_project_id "$PROJECT") || { log "ERROR" "Failed to get project"; exit 0; }
debug "Using project: $PROJECT (id: $PROJECT_ID)"

EXISTING_ROOT=$(get_session_state "$SESSION_ID" "root_span_id")
[ -n "$EXISTING_ROOT" ] && { debug "Session already has root span"; exit 0; }

TRACE_ID=$(echo "$SESSION_ID" | sed 's/-//g' | head -c 32)
while [ ${#TRACE_ID} -lt 32 ]; do TRACE_ID="${TRACE_ID}0"; done
SPAN_ID=$(generate_uuid | sed 's/-//g' | head -c 16)

WORKSPACE=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
WORKSPACE_NAME=$(basename "$WORKSPACE" 2>/dev/null || echo "Claude Code")
START_TIME=$(get_time_nanos)

ATTRIBUTES=$(build_otlp_attributes "$(jq -n \
    --arg span_kind "task" \
    --arg input "Session: $WORKSPACE_NAME" \
    --arg session_id "$SESSION_ID" \
    --arg workspace "$WORKSPACE" \
    --arg hostname "$(get_hostname)" \
    --arg username "$(get_username)" \
    --arg os "$(get_os)" \
    '{
        "judgment.span_kind": $span_kind,
        "judgment.input": $input,
        "session_id": $session_id,
        "workspace": $workspace,
        "hostname": $hostname,
        "username": $username,
        "os": $os,
        "source": "claude-code"
    }')")

SPAN=$(build_otlp_span "$TRACE_ID" "$SPAN_ID" "" "Claude Code: $WORKSPACE_NAME" "task" "$START_TIME" "$START_TIME" "$ATTRIBUTES" 0)
insert_span "$PROJECT_ID" "$SPAN" || { log "ERROR" "Failed to create session root"; exit 0; }

set_session_state_batch "$SESSION_ID" \
    "trace_id" "$TRACE_ID" \
    "root_span_id" "$SPAN_ID" \
    "project_id" "$PROJECT_ID" \
    "turn_count" "0" \
    "tool_count" "0" \
    "started" "$START_TIME"

log "INFO" "Created session: trace=$TRACE_ID workspace=$WORKSPACE_NAME"
exit 0
