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
[ -n "$DEBUG_ON" ] && debug "SessionEnd input: $(echo "$INPUT" | jq -c '.' 2>/dev/null | head -c 500)"

echo "$INPUT" | jq -e '.' >/dev/null 2>&1 || { debug "Invalid JSON"; exit 0; }

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
[ -z "$SESSION_ID" ] && { debug "No session ID"; exit 0; }

IFS=$'\x1f' read -r TRACE_ID PROJECT_ID ROOT_SPAN_ID TASK_SPAN_ID SESSION_START WORKSPACE OFFSET \
    <<< "$(get_session_fields "$SESSION_ID" trace_id project_id root_span_id current_task_span_id started workspace transcript_offset)"

[ -z "$TRACE_ID" ] && { debug "No current trace"; exit 0; }
[ -z "$ROOT_SPAN_ID" ] || [ -z "$PROJECT_ID" ] && { debug "No trace/project"; exit 0; }

CONV_FILE=$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
[ -z "$CONV_FILE" ] || [ ! -f "$CONV_FILE" ] && \
    CONV_FILE=$(find "$HOME/.claude/projects" -name "${SESSION_ID}.jsonl" -type f 2>/dev/null | head -1)

[ -z "$WORKSPACE" ] && WORKSPACE=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)

# Sweep any transcript lines the last Stop hook didn't process. If a turn
# is still open (session killed mid-turn), parent the sweep to it so the
# spans land in the right place; otherwise parent to the root span.
SPAN_BATCH=()
LAST_OUTPUT=""
if [ -n "$CONV_FILE" ] && [ -f "$CONV_FILE" ]; then
    PARSE_FILE="$CONV_FILE"
    PARSE_OFFSET="${OFFSET:-0}"
    PARSE_TRACE_ID="$TRACE_ID"
    PARSE_PROJECT_ID="$PROJECT_ID"
    PARSE_SESSION_ID="$SESSION_ID"
    PARSE_PARENT_SPAN_ID="${TASK_SPAN_ID:-$ROOT_SPAN_ID}"
    PARSE_HISTORY_FILE=$(session_history_file "$SESSION_ID")
    parse_transcript_chunk
    LAST_OUTPUT="$PARSE_LAST_OUTPUT"

    if [ -n "$TASK_SPAN_ID" ]; then
        finalize_task_span "$TASK_SPAN_ID" "$ROOT_SPAN_ID" "$SESSION_ID" ""
        log "INFO" "Open turn finalized at session end ($PARSE_LLM_CALLS llm, $PARSE_TOOL_CALLS tool spans)"
    elif [ "$PARSE_LLM_CALLS" -gt 0 ] || [ "$PARSE_TOOL_CALLS" -gt 0 ]; then
        log "INFO" "Sweep created $PARSE_LLM_CALLS llm, $PARSE_TOOL_CALLS tool spans"
    fi
fi

END_TIME=$(get_time_nanos)
SESSION_START=${SESSION_START:-$END_TIME}
# completed_sessions still holds the PREVIOUS trace here (this one is
# recorded below), so the finalize update keeps the creation-time link.
LINK_ATTRS=$(previous_trace_link_attrs "$SESSION_ID")
SESSION_ATTRS=$(build_root_span_attrs "$SESSION_ID" "$WORKSPACE" "${LAST_OUTPUT:-Completed}" "$LINK_ATTRS")
SESSION_SPAN=$(build_otlp_span "$TRACE_ID" "$ROOT_SPAN_ID" "" "Claude Code: $(workspace_display_name "$WORKSPACE")" "task" "$SESSION_START" "$END_TIME" "$SESSION_ATTRS" 20)
SPAN_BATCH+=("$SESSION_SPAN")
flush_span_batch "$PROJECT_ID" || debug "Failed to finalize session"

# Remember this trace so a resumed session's next trace can link back to
# it, then clean up only this session's live state; other sessions keep
# theirs. The history file is kept intentionally: Claude Code --resume
# reuses the session id and restores the conversation, so the next trace's
# LLM spans should keep the prior context. Old files age out below.
record_completed_trace "$SESSION_ID" "$TRACE_ID" "$ROOT_SPAN_ID"
clear_session_state "$SESSION_ID"
find "$HOME/.claude/state" -name 'judgeval_history_*.json' -mtime +7 -delete 2>/dev/null || true

log "INFO" "Trace ended: $TRACE_ID (session=$SESSION_ID)"
exit 0
