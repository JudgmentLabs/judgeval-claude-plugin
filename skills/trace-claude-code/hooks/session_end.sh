#!/bin/bash
###
# SessionEnd Hook - Sweeps any unprocessed transcript tail and finalizes
# the root trace span.
#
# Per-turn LLM/tool spans are created live by stop_hook.sh; this hook only
# catches content the last Stop missed (or an entire session's worth if
# Stop never fired) and closes out the session.
###

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"
# shellcheck source=transcript_parser.sh
source "$SCRIPT_DIR/transcript_parser.sh"

debug "SessionEnd hook triggered"
tracing_enabled || { debug "Tracing disabled"; exit 0; }
check_requirements || exit 0

INPUT=$(cat)
debug "SessionEnd input: $(echo "$INPUT" | jq -c '.' 2>/dev/null | head -c 500)"

echo "$INPUT" | jq -e '.' >/dev/null 2>&1 || { debug "Invalid JSON"; exit 0; }

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
[ -z "$SESSION_ID" ] && { debug "No session ID"; exit 0; }

TRACE_ID=$(get_session_state "$SESSION_ID" "trace_id")
[ -z "$TRACE_ID" ] && { debug "No current trace"; exit 0; }

ROOT_SPAN_ID=$(get_session_state "$SESSION_ID" "root_span_id")
PROJECT_ID=$(get_session_state "$SESSION_ID" "project_id")
TASK_SPAN_ID=$(get_session_state "$SESSION_ID" "current_task_span_id")
TASK_START=$(get_session_state "$SESSION_ID" "current_task_start")
TASK_INPUT=$(get_session_state "$SESSION_ID" "current_task_input")
SESSION_START=$(get_session_state "$SESSION_ID" "started")
WORKSPACE=$(get_session_state "$SESSION_ID" "workspace")
WORKSPACE_NAME=$(get_session_state "$SESSION_ID" "workspace_name")
OFFSET=$(get_session_state "$SESSION_ID" "transcript_offset")

[ -z "$ROOT_SPAN_ID" ] || [ -z "$PROJECT_ID" ] && { debug "No trace/project"; exit 0; }

CONV_FILE=$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
[ -z "$CONV_FILE" ] || [ ! -f "$CONV_FILE" ] && \
    CONV_FILE=$(find "$HOME/.claude/projects" -name "${SESSION_ID}.jsonl" -type f 2>/dev/null | head -1)

CWD_INPUT=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
[ -z "$WORKSPACE_NAME" ] && WORKSPACE_NAME=$(basename "${CWD_INPUT:-.}" 2>/dev/null || echo "Claude Code")
[ -z "$WORKSPACE_NAME" ] || [ "$WORKSPACE_NAME" = "." ] && WORKSPACE_NAME="Claude Code"
[ -z "$WORKSPACE" ] && WORKSPACE="$CWD_INPUT"

# Sweep any transcript lines the last Stop hook didn't process. If a turn
# is still open (session killed mid-turn), parent the sweep to it so the
# spans land in the right place; otherwise parent to the root span.
LAST_OUTPUT=""
if [ -n "$CONV_FILE" ] && [ -f "$CONV_FILE" ]; then
    PARSE_FILE="$CONV_FILE"
    PARSE_OFFSET="${OFFSET:-0}"
    PARSE_TRACE_ID="$TRACE_ID"
    PARSE_PROJECT_ID="$PROJECT_ID"
    PARSE_PARENT_SPAN_ID="${TASK_SPAN_ID:-$ROOT_SPAN_ID}"
    PARSE_HISTORY_FILE=$(session_history_file "$SESSION_ID")
    parse_transcript_chunk
    LAST_OUTPUT="$PARSE_LAST_OUTPUT"

    if [ -n "$TASK_SPAN_ID" ]; then
        TASK_END="${PARSE_LAST_TS_NANOS:-$(get_time_nanos)}"
        TASK_START="${TASK_START:-$TASK_END}"
        if [ -n "$PARSE_FIRST_TS_NANOS" ] && [ "$PARSE_FIRST_TS_NANOS" -lt "$TASK_START" ] 2>/dev/null; then
            TASK_START="$PARSE_FIRST_TS_NANOS"
        fi
        TASK_INPUT="${TASK_INPUT:-${PARSE_FIRST_USER_INPUT:-}}"
        TASK_INPUT_JSON=$(echo "$TASK_INPUT" | jq -Rs '.')
        TASK_ATTRS=$(build_otlp_attributes "$(jq -n \
            --arg span_kind "task" \
            --argjson input "$TASK_INPUT_JSON" \
            --arg output "${LAST_OUTPUT:-Completed}" \
            --argjson llm "$PARSE_LLM_CALLS" \
            --argjson tools "$PARSE_TOOL_CALLS" \
            --arg session_id "$SESSION_ID" \
            '{"judgment.span_kind": $span_kind, "judgment.input": $input, "judgment.output": $output, "llm_call_count": $llm, "tool_count": $tools, "session_id": $session_id}')")
        TASK_SPAN=$(build_otlp_span "$TRACE_ID" "$TASK_SPAN_ID" "$ROOT_SPAN_ID" "Task" "task" "$TASK_START" "$TASK_END" "$TASK_ATTRS" 20)
        insert_span "$PROJECT_ID" "$TASK_SPAN" >/dev/null || debug "Failed to finalize task"
        log "INFO" "Open turn finalized at session end ($PARSE_LLM_CALLS llm, $PARSE_TOOL_CALLS tool spans)"
    elif [ "$PARSE_LLM_CALLS" -gt 0 ] || [ "$PARSE_TOOL_CALLS" -gt 0 ]; then
        log "INFO" "Sweep created $PARSE_LLM_CALLS llm, $PARSE_TOOL_CALLS tool spans"
    fi
fi

# Finalize the root span with the same attributes it was created with so
# the update doesn't drop hostname/workspace/etc.
END_TIME=$(get_time_nanos)
SESSION_START=${SESSION_START:-$END_TIME}
SESSION_ATTRS=$(build_otlp_attributes "$(jq -n \
    --arg span_kind "task" \
    --arg input "Session: $WORKSPACE_NAME" \
    --arg output "${LAST_OUTPUT:-Completed}" \
    --arg session_id "$SESSION_ID" \
    --arg workspace "${WORKSPACE:-}" \
    --arg hostname "$(get_hostname)" \
    --arg username "$(get_username)" \
    --arg os "$(get_os)" \
    '{
        "judgment.span_kind": $span_kind,
        "judgment.input": $input,
        "judgment.output": $output,
        "session_id": $session_id,
        "workspace": $workspace,
        "hostname": $hostname,
        "username": $username,
        "os": $os,
        "source": "claude-code"
    }')")
SESSION_SPAN=$(build_otlp_span "$TRACE_ID" "$ROOT_SPAN_ID" "" "Claude Code: $WORKSPACE_NAME" "task" "$SESSION_START" "$END_TIME" "$SESSION_ATTRS" 20)
insert_span "$PROJECT_ID" "$SESSION_SPAN" || debug "Failed to finalize session"

# Clean up only this session's state; other live sessions keep theirs.
clear_session_state "$SESSION_ID"
rm -f "$(session_history_file "$SESSION_ID")" 2>/dev/null || true

log "INFO" "Trace ended: $TRACE_ID (session=$SESSION_ID)"
exit 0
