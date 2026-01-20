#!/bin/bash
###
# UserPromptSubmit Hook - Creates Turn span when user submits a prompt
###

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

debug "UserPromptSubmit hook triggered"
tracing_enabled || { debug "Tracing disabled"; exit 0; }
check_requirements || exit 0

INPUT=$(cat)
debug "UserPromptSubmit input: $(echo "$INPUT" | jq -c '.' 2>/dev/null | head -c 500)"

echo "$INPUT" | jq -e '.' >/dev/null 2>&1 || { debug "Invalid JSON"; exit 0; }

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
PROMPT=$(echo "$INPUT" | jq -r '.prompt // empty' 2>/dev/null)
[ -z "$SESSION_ID" ] && { debug "No session ID"; exit 0; }

TRACE_ID=$(get_session_state "$SESSION_ID" "trace_id")
ROOT_SPAN_ID=$(get_session_state "$SESSION_ID" "root_span_id")
PROJECT_ID=$(get_session_state "$SESSION_ID" "project_id")

if [ -z "$TRACE_ID" ] || [ -z "$PROJECT_ID" ]; then
    PROJECT_ID=$(get_project_id "$PROJECT") || { log "ERROR" "Failed to get project"; exit 0; }
    
    TRACE_ID=$(echo "$SESSION_ID" | sed 's/-//g' | head -c 32)
    while [ ${#TRACE_ID} -lt 32 ]; do TRACE_ID="${TRACE_ID}0"; done
    ROOT_SPAN_ID=$(generate_uuid | sed 's/-//g' | head -c 16)

    CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
    WORKSPACE_NAME=$(basename "$CWD" 2>/dev/null || echo "workspace")
    SESSION_START=$(get_time_nanos)
    
    ATTRIBUTES=$(build_otlp_attributes "$(jq -n \
        --arg span_kind "task" \
        --arg input "Session: $WORKSPACE_NAME" \
        --arg session_id "$SESSION_ID" \
        '{ "judgment.span_kind": $span_kind, "judgment.input": $input, "session_id": $session_id, "source": "claude-code" }')")

    SPAN=$(build_otlp_span "$TRACE_ID" "$ROOT_SPAN_ID" "" "Claude Code: $WORKSPACE_NAME" "task" "$SESSION_START" "$SESSION_START" "$ATTRIBUTES" 0)
    insert_span "$PROJECT_ID" "$SPAN" >/dev/null || true

    set_session_state_batch "$SESSION_ID" \
        "trace_id" "$TRACE_ID" \
        "root_span_id" "$ROOT_SPAN_ID" \
        "project_id" "$PROJECT_ID" \
        "started" "$SESSION_START" \
        "turn_count" "0"
fi

TURN_COUNT=$(get_session_state "$SESSION_ID" "turn_count")
TURN_COUNT=$((${TURN_COUNT:-0} + 1))

TURN_SPAN_ID=$(generate_uuid | sed 's/-//g' | head -c 16)
START_TIME=$(get_time_nanos)
PROMPT_JSON=$(echo "$PROMPT" | jq -Rs '.')

ATTRIBUTES=$(build_otlp_attributes "$(jq -n \
    --arg span_kind "task" \
    --argjson input "$PROMPT_JSON" \
    --argjson turn "$TURN_COUNT" \
    '{ "judgment.span_kind": $span_kind, "judgment.input": $input, "turn_number": $turn }')")

SPAN=$(build_otlp_span "$TRACE_ID" "$TURN_SPAN_ID" "$ROOT_SPAN_ID" "Turn $TURN_COUNT" "task" "$START_TIME" "$START_TIME" "$ATTRIBUTES" 0)
insert_span "$PROJECT_ID" "$SPAN" || { log "ERROR" "Failed to create turn span"; exit 0; }

set_session_state_batch "$SESSION_ID" \
    "turn_count" "$TURN_COUNT" \
    "current_turn_span_id" "$TURN_SPAN_ID" \
    "current_turn_start" "$START_TIME" \
    "current_turn_tool_count" "0" \
    "turn_last_line" "0"

log "INFO" "Turn $TURN_COUNT started: span=$TURN_SPAN_ID"
exit 0
