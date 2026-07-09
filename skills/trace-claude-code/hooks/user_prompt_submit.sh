#!/bin/bash
###
# UserPromptSubmit Hook - Opens one trace for the user turn.
###

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

debug "UserPromptSubmit hook triggered"
tracing_enabled || { debug "Tracing disabled"; exit 0; }
check_requirements || exit 0

INPUT=$(cat)
debug "UserPromptSubmit input: $(echo "$INPUT" | jq -c '.' 2>/dev/null | head -c 500)"

echo "$INPUT" | jq -e '.' >/dev/null 2>&1 || { debug "Invalid JSON"; exit 0; }

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
[ -z "$SESSION_ID" ] && SESSION_ID=$(generate_uuid)

PROMPT=$(echo "$INPUT" | jq -r '.prompt // empty' 2>/dev/null)
WORKSPACE=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
[ -z "$WORKSPACE" ] && WORKSPACE=$(get_session_state "$SESSION_ID" "workspace")
WORKSPACE_NAME=$(basename "$WORKSPACE" 2>/dev/null || echo "Claude Code")

TRANSCRIPT_PATH=$(find_transcript_path "$SESSION_ID" "$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)" || true)
[ -z "$TRANSCRIPT_PATH" ] && TRANSCRIPT_PATH=$(get_session_state "$SESSION_ID" "transcript_path")

PROJECT_ID=$(get_session_state "$SESSION_ID" "project_id")
[ -z "$PROJECT_ID" ] && PROJECT_ID=$(get_project_id "$PROJECT")
[ -z "$PROJECT_ID" ] && { log "ERROR" "Failed to get project"; exit 0; }

OFFSET=$(get_session_state "$SESSION_ID" "transcript_offset")
[ -z "$OFFSET" ] && OFFSET=$(count_file_lines "$TRANSCRIPT_PATH")

TURN_INDEX=$(get_session_state "$SESSION_ID" "turn_count")
TURN_INDEX=$((${TURN_INDEX:-0} + 1))

TRACE_ID=$(generate_trace_id)
ROOT_SPAN_ID=$(generate_span_id)
TASK_SPAN_ID=$(generate_span_id)
START_TIME=$(get_time_nanos)
PROMPT_JSON=$(echo "$PROMPT" | jq -Rs '.')

ROOT_ATTRS=$(build_otlp_attributes "$(jq -n \
    --arg span_kind "task" \
    --argjson input "$PROMPT_JSON" \
    --arg session_id "$SESSION_ID" \
    --arg workspace "$WORKSPACE" \
    --arg hostname "$(get_hostname)" \
    --arg username "$(get_username)" \
    --arg os "$(get_os)" \
    --argjson turn_index "$TURN_INDEX" \
    '{
        "judgment.span_kind": $span_kind,
        "judgment.input": $input,
        "judgment.output": "",
        "judgment.session_id": $session_id,
        "session_id": $session_id,
        "turn_index": $turn_index,
        "workspace": $workspace,
        "hostname": $hostname,
        "username": $username,
        "os": $os,
        "source": "claude-code"
    }')"
)
ROOT_SPAN=$(build_otlp_span "$TRACE_ID" "$ROOT_SPAN_ID" "" "Claude Code Turn: $WORKSPACE_NAME" "task" "$START_TIME" "$START_TIME" "$ROOT_ATTRS" 0)
insert_span_sync "$PROJECT_ID" "$ROOT_SPAN" >/dev/null || { log "ERROR" "Failed to create turn trace root"; exit 0; }

TASK_ATTRS=$(build_otlp_attributes "$(jq -n \
    --arg span_kind "task" \
    --argjson input "$PROMPT_JSON" \
    --arg session_id "$SESSION_ID" \
    --argjson turn_index "$TURN_INDEX" \
    '{
        "judgment.span_kind": $span_kind,
        "judgment.input": $input,
        "judgment.output": "",
        "judgment.session_id": $session_id,
        "session_id": $session_id,
        "turn_index": $turn_index
    }')"
)
TASK_SPAN=$(build_otlp_span "$TRACE_ID" "$TASK_SPAN_ID" "$ROOT_SPAN_ID" "Task" "task" "$START_TIME" "$START_TIME" "$TASK_ATTRS" 0)
insert_span "$PROJECT_ID" "$TASK_SPAN" >/dev/null || { log "ERROR" "Failed to create task span"; exit 0; }

set_session_state_batch "$SESSION_ID" \
    "project_id" "$PROJECT_ID" \
    "workspace" "${WORKSPACE:-}" \
    "transcript_path" "${TRANSCRIPT_PATH:-}" \
    "turn_count" "$TURN_INDEX" \
    "active_trace_id" "$TRACE_ID" \
    "active_root_span_id" "$ROOT_SPAN_ID" \
    "active_task_span_id" "$TASK_SPAN_ID" \
    "active_trace_start" "$START_TIME" \
    "active_task_start" "$START_TIME" \
    "active_prompt" "$PROMPT" \
    "active_transcript_offset" "${OFFSET:-0}"

set_state_value "current_trace_id" "$TRACE_ID"

log "INFO" "Turn trace started: trace=$TRACE_ID session=$SESSION_ID turn=$TURN_INDEX"
exit 0
