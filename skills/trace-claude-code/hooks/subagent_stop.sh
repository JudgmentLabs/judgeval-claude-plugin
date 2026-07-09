#!/bin/bash
###
# SubagentStop Hook - Creates spans for subagent execution
#
# Creates a container span for the completed subagent and parses its
# transcript into LLM/tool spans via the shared transcript parser (offset 0,
# sidechain lines included, subagent_id stamped on every span). All spans go
# out in one batched OTLP request.
###

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"
# shellcheck source=transcript_parser.sh
source "$SCRIPT_DIR/transcript_parser.sh"

debug "SubagentStop hook triggered"
tracing_enabled || { debug "Tracing disabled"; exit 0; }
check_requirements || exit 0

INPUT=$(cat)
[ -n "$DEBUG_ON" ] && debug "SubagentStop input: $(echo "$INPUT" | jq -c '.' 2>/dev/null | head -c 1000)"

echo "$INPUT" | jq -e '.' >/dev/null 2>&1 || { debug "Invalid JSON"; exit 0; }

SUBAGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // .subagent_id // empty' 2>/dev/null)
SUBAGENT_TRANSCRIPT=$(echo "$INPUT" | jq -r '.agent_transcript_path // empty' 2>/dev/null)
TASK_DESCRIPTION=$(echo "$INPUT" | jq -r '.task // .description // empty' 2>/dev/null)
LAST_ASSISTANT=$(echo "$INPUT" | jq -r '.last_assistant_message // empty' 2>/dev/null)
PARENT_SESSION_ID=$(echo "$INPUT" | jq -r '.parent_session_id // .session_id // empty' 2>/dev/null)
[ -z "$PARENT_SESSION_ID" ] && { debug "No session ID"; exit 0; }

# Get parent trace context (keyed by the parent session)
IFS=$'\x1f' read -r TRACE_ID PROJECT_ID ROOT_SPAN_ID PARENT_TASK_SPAN_ID \
    <<< "$(get_session_fields "$PARENT_SESSION_ID" trace_id project_id root_span_id current_task_span_id)"

[ -z "$TRACE_ID" ] && { debug "No current trace"; exit 0; }
[ -z "$PROJECT_ID" ] || [ -z "$ROOT_SPAN_ID" ] && { debug "No trace/project"; exit 0; }

# Use task span as parent if available, otherwise root
PARENT_SPAN_ID="${PARENT_TASK_SPAN_ID:-$ROOT_SPAN_ID}"
SUBAGENT_SPAN_ID=$(generate_uuid | sed 's/-//g' | head -c 16)

# The provided agent_transcript_path may not be written yet when this hook
# fires (observed live). Back off briefly, checking fallback locations
# between waits so a found file short-circuits the wait.
find_subagent_transcript() {
    [ -n "$SUBAGENT_TRANSCRIPT" ] && [ -f "$SUBAGENT_TRANSCRIPT" ] && return 0
    if [ -n "$SUBAGENT_ID" ]; then
        local pattern FOUND
        for pattern in \
            "$HOME/.claude/projects/*/*/subagents/agent-${SUBAGENT_ID}.jsonl" \
            "$HOME/.claude/projects/*/agent-${SUBAGENT_ID}.jsonl" \
            "$HOME/.claude/projects/*/${SUBAGENT_ID}.jsonl"; do
            FOUND=$(find $pattern -type f 2>/dev/null | head -1)
            if [ -n "$FOUND" ] && [ -f "$FOUND" ]; then
                SUBAGENT_TRANSCRIPT="$FOUND"
                debug "Found subagent transcript: $SUBAGENT_TRANSCRIPT"
                return 0
            fi
        done
    fi
    return 1
}
for wait in 0 0.1 0.2 0.4 0.8; do
    [ "$wait" != "0" ] && sleep "$wait"
    find_subagent_transcript && break
done

SPAN_BATCH=()
PARSE_LLM_CALLS=0
PARSE_TOOL_CALLS=0
PARSE_LAST_OUTPUT=""
PARSE_FIRST_TS_NANOS=""
if [ -n "$SUBAGENT_TRANSCRIPT" ] && [ -f "$SUBAGENT_TRANSCRIPT" ]; then
    PARSE_FILE="$SUBAGENT_TRANSCRIPT"
    PARSE_OFFSET=0
    PARSE_TRACE_ID="$TRACE_ID"
    PARSE_PROJECT_ID="$PROJECT_ID"
    PARSE_SESSION_ID="$PARENT_SESSION_ID"
    PARSE_PARENT_SPAN_ID="$SUBAGENT_SPAN_ID"
    PARSE_HISTORY_FILE=""
    PARSE_INCLUDE_SIDECHAIN=1
    PARSE_EXTRA_ATTRS=$(jq -cn --arg id "${SUBAGENT_ID:-unknown}" '{subagent_id: $id}')
    parse_transcript_chunk
    PARSE_EXTRA_ATTRS=""
    PARSE_INCLUDE_SIDECHAIN=0
else
    debug "No subagent transcript available"
fi

# Container span: prefer real data over placeholders — transcript timestamps
# for the window, last assistant message when the transcript was unavailable.
END_TIME=$(get_time_nanos)
START_TIME="${PARSE_FIRST_TS_NANOS:-$END_TIME}"
SUBAGENT_OUTPUT="${PARSE_LAST_OUTPUT:-${LAST_ASSISTANT:-Completed}}"

SUBAGENT_ATTRS=$(build_otlp_attributes "$(jq -n \
    --arg input "${TASK_DESCRIPTION:-Subagent task}" \
    --arg output "$SUBAGENT_OUTPUT" \
    --arg subagent_id "${SUBAGENT_ID:-unknown}" \
    --argjson llm_calls "$PARSE_LLM_CALLS" \
    --argjson tool_calls "$PARSE_TOOL_CALLS" \
    --arg session_id "$PARENT_SESSION_ID" \
    '{
        "judgment.span_kind": "task",
        "judgment.input": $input,
        "judgment.output": $output,
        "subagent_id": $subagent_id,
        "llm_call_count": $llm_calls,
        "tool_count": $tool_calls,
        "judgment.session_id": $session_id
    }')")
SUBAGENT_SPAN=$(build_otlp_span "$TRACE_ID" "$SUBAGENT_SPAN_ID" "$PARENT_SPAN_ID" "Subagent: ${SUBAGENT_ID:-task}" "task" "$START_TIME" "$END_TIME" "$SUBAGENT_ATTRS" 20)
SPAN_BATCH+=("$SUBAGENT_SPAN")

if flush_span_batch "$PROJECT_ID"; then
    log "INFO" "Subagent traced: ${SUBAGENT_ID:-unknown} (llm=$PARSE_LLM_CALLS, tools=$PARSE_TOOL_CALLS)"
else
    log "ERROR" "Failed to send subagent spans"
fi

exit 0
