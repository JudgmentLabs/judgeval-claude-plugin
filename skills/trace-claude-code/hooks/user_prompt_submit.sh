#!/bin/bash
###
# UserPromptSubmit Hook - Creates Task span when user submits a prompt
###

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"
# shellcheck source=transcript_parser.sh
source "$SCRIPT_DIR/transcript_parser.sh"

debug "UserPromptSubmit hook triggered"
tracing_enabled || { debug "Tracing disabled"; exit 0; }
check_requirements || exit 0

INPUT=$(cat)
debug "UserPromptSubmit input: $(echo "$INPUT" | jq -c '.' 2>/dev/null | head -c 500)"

echo "$INPUT" | jq -e '.' >/dev/null 2>&1 || { debug "Invalid JSON"; exit 0; }

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
PROMPT=$(echo "$INPUT" | jq -r '.prompt // empty' 2>/dev/null)
WORKSPACE=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)

[ -z "$SESSION_ID" ] && { debug "No session ID"; exit 0; }

# Lazily create the trace if SessionStart never fired for this session
# (e.g. plugin installed mid-session). ensure_trace starts the transcript
# offset at the file's current end so the untraced past isn't misattributed
# to this turn.
ensure_trace "$SESSION_ID" "$WORKSPACE" "$TRANSCRIPT_PATH" || { debug "No trace available"; exit 0; }

IFS=$'\x1f' read -r ROOT_SPAN_ID PROJECT_ID STALE_TASK_SPAN_ID OFFSET \
    <<< "$(get_session_fields "$SESSION_ID" root_span_id project_id current_task_span_id transcript_offset)"

[ -z "$ROOT_SPAN_ID" ] || [ -z "$PROJECT_ID" ] && { debug "Missing trace state"; exit 0; }

# A still-open task span means the previous turn never saw its Stop hook
# (user interrupt) or its spans failed to send. Finalize it now, under its
# own span, before starting the new turn — otherwise it sits 0-duration
# forever and its transcript lines get misattributed to this turn.
if [ -n "$STALE_TASK_SPAN_ID" ]; then
    PARSE_FILE="$TRANSCRIPT_PATH"
    [ -z "$PARSE_FILE" ] || [ ! -f "$PARSE_FILE" ] && \
        PARSE_FILE=$(find "$HOME/.claude/projects" -name "${SESSION_ID}.jsonl" -type f 2>/dev/null | head -1)
    PARSE_OFFSET="${OFFSET:-0}"
    PARSE_TRACE_ID="$TRACE_ID"
    PARSE_PROJECT_ID="$PROJECT_ID"
    PARSE_SESSION_ID="$SESSION_ID"
    PARSE_PARENT_SPAN_ID="$STALE_TASK_SPAN_ID"
    PARSE_HISTORY_FILE=$(session_history_file "$SESSION_ID")
    parse_transcript_chunk
    finalize_task_span "$STALE_TASK_SPAN_ID" "$ROOT_SPAN_ID" "$SESSION_ID" "[interrupted by user]"
    if flush_span_batch "$PROJECT_ID"; then
        set_session_state_batch "$SESSION_ID" "transcript_offset" "$PARSE_NEW_OFFSET"
        save_parse_history
        log "INFO" "Recovered interrupted turn: $PARSE_LLM_CALLS llm, $PARSE_TOOL_CALLS tool spans (session=$SESSION_ID)"
    else
        log "ERROR" "Interrupted-turn spans not delivered; will retry (session=$SESSION_ID)"
    fi
fi

TASK_SPAN_ID=$(generate_uuid | sed 's/-//g' | head -c 16)
START_TIME=$(get_time_nanos)
PROMPT_JSON=$(echo "$PROMPT" | jq -Rs '.')

ATTRIBUTES=$(build_otlp_attributes "$(jq -n \
    --arg span_kind "task" \
    --argjson input "$PROMPT_JSON" \
    --arg session_id "$SESSION_ID" \
    '{ "judgment.span_kind": $span_kind, "judgment.input": $input, "judgment.session_id": $session_id }')")

SPAN=$(build_otlp_span "$TRACE_ID" "$TASK_SPAN_ID" "$ROOT_SPAN_ID" "Task" "task" "$START_TIME" "$START_TIME" "$ATTRIBUTES" 0)
insert_span "$PROJECT_ID" "$SPAN" || { log "ERROR" "Failed to create task span"; exit 0; }

set_session_state "$SESSION_ID" "current_task_span_id" "$TASK_SPAN_ID"

log "INFO" "Task started: span=$TASK_SPAN_ID (session=$SESSION_ID)"
exit 0
