#!/bin/bash
###
# SubagentStart Hook - real-time subagent container span.
#
# Fires when a subagent is spawned. Writes the durable parent-trace mapping
# immediately (so SubagentStop, task notifications, and follow-ups never
# race the turn's finalize job for it) and queues a placeholder container
# span so the subagent is visible on the platform while it runs. The
# SubagentStop processing re-emits the same span id with a higher update_id
# to fill in real timing, input/output, and counts.
###

set -e
trap 'exit 0' ERR
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

debug "SubagentStart hook triggered"
tracing_enabled || { debug "Tracing disabled"; exit 0; }
check_requirements || exit 0

INPUT=$(cat)
debug "SubagentStart input: $(echo "$INPUT" | jq -c '.' 2>/dev/null | head -c 500)"

echo "$INPUT" | jq -e '.' >/dev/null 2>&1 || { debug "Invalid JSON"; exit 0; }

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)
AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // empty' 2>/dev/null || true)
AGENT_TYPE=$(echo "$INPUT" | jq -r '.agent_type // empty' 2>/dev/null || true)

[ -z "$SESSION_ID" ] || [ -z "$AGENT_ID" ] && { debug "No session/agent id"; exit 0; }

# Internal utility agents (prompt suggestions, summaries, titles) spawn with
# an empty agent_type and are not traced (see subagent_stop.sh).
if [ -z "$AGENT_TYPE" ]; then
    debug "Skipping SubagentStart for internal agent $AGENT_ID"
    exit 0
fi

IFS=$'\x1f' read -r TRACE_ID PROJECT_ID ROOT_SPAN_ID TASK_SPAN_ID TURN_INDEX WORKSPACE \
    <<< "$(get_session_fields "$SESSION_ID" active_trace_id project_id active_root_span_id active_task_span_id turn_count workspace)"

if [ -z "$TRACE_ID" ] || [ -z "$TASK_SPAN_ID" ]; then
    debug "No active turn trace at subagent start; skipping realtime span"
    exit 0
fi

SUBAGENT_SPAN_ID=$(generate_span_id)
NOW=$(get_time_nanos)

# Durable mapping written at spawn: SubagentStop and notification handling
# find their parent trace context here without racing the finalize job.
set_session_state_batch "subagent:$AGENT_ID" \
    "parent_session_id" "$SESSION_ID" \
    "trace_id" "$TRACE_ID" \
    "project_id" "${PROJECT_ID:-}" \
    "root_span_id" "${ROOT_SPAN_ID:-}" \
    "task_span_id" "$TASK_SPAN_ID" \
    "turn_index" "${TURN_INDEX:-1}" \
    "description" "$AGENT_TYPE" \
    "subagent_span_id" "$SUBAGENT_SPAN_ID" \
    "subagent_started_at" "$NOW"

EVENT=$(jq -cn \
    --arg project_id "${PROJECT_ID:-}" \
    --arg project_name "$PROJECT" \
    --arg trace_id "$TRACE_ID" \
    --arg span_id "$SUBAGENT_SPAN_ID" \
    --arg parent_span_id "$TASK_SPAN_ID" \
    --arg agent_id "$AGENT_ID" \
    --arg agent_type "$AGENT_TYPE" \
    --arg start_time "$NOW" \
    --arg session_id "$SESSION_ID" \
    --arg turn_index "${TURN_INDEX:-1}" \
    '{type: "subagent_start", attempts: 0, project_id: $project_id, project_name: $project_name,
      trace_id: $trace_id, span_id: $span_id, parent_span_id: $parent_span_id,
      agent_id: $agent_id, agent_type: $agent_type, start_time: $start_time,
      session_id: $session_id, turn_index: $turn_index}' 2>/dev/null || true)
[ -n "$EVENT" ] && enqueue_payload "$EVENT"

log "INFO" "Subagent started: $AGENT_ID ($AGENT_TYPE) trace=$TRACE_ID session=$SESSION_ID"
exit 0
