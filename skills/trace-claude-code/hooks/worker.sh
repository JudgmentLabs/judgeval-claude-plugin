#!/bin/bash
###
# Background queue worker - uploads queued spans to the Judgment API.
#
# Hooks never touch the network; they enqueue span files under
# $QUEUE_DIR/pending/ (via insert_span in common.sh) and spawn this worker.
# One worker runs at a time (pid-file lock). It drains the queue oldest-first,
# resolves the project id by name when a file was enqueued before the id was
# cached, and exits after a period with nothing to do; the next enqueue
# respawns it. All network calls are time-bounded.
#
# Queue file format: {project_id, project_name, attempts, span}
###

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"
# shellcheck source=turn_trace_common.sh
source "$SCRIPT_DIR/turn_trace_common.sh"

PENDING="$QUEUE_DIR/pending"
PROCESSING="$QUEUE_DIR/processing"
PID_FILE="$QUEUE_DIR/worker.pid"
MAX_ATTEMPTS=5
IDLE_EXIT_SECS=60

mkdir -p "$PENDING" "$PROCESSING" 2>/dev/null || exit 0

# Single-worker lock via noclobber pid file. If another live worker holds it,
# exit; a stale file from a dead worker is replaced.
claim_lock() {
    local owner
    if ( set -C; echo "$$" > "$PID_FILE" ) 2>/dev/null; then
        return 0
    fi
    owner=$(cat "$PID_FILE" 2>/dev/null)
    if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
        return 1
    fi
    rm -f "$PID_FILE" 2>/dev/null
    ( set -C; echo "$$" > "$PID_FILE" ) 2>/dev/null
}

claim_lock || exit 0

cleanup() {
    if [ "$(cat "$PID_FILE" 2>/dev/null)" = "$$" ]; then
        rm -f "$PID_FILE" 2>/dev/null
    fi
}
trap cleanup EXIT

# Recover files a previous worker left mid-flight.
for f in "$PROCESSING"/*.json; do
    [ -e "$f" ] || continue
    mv -f "$f" "$PENDING/$(basename "$f")" 2>/dev/null || true
done

debug "Queue worker $$ started"

# Finalize a turn whose Stop hook was killed before completing. Runs the
# normal transcript parse and finalization bounded to that turn's slice;
# the spans it produces are enqueued and uploaded by this same loop. Runs
# once per job — parsing is deterministic and local, so a failure here
# would fail identically on retry.
run_finalize_job() {
    local job="$1"
    TURN_SESSION_ID=$(jq -r '.session_id // empty' "$job")
    TURN_TRACE_ID=$(jq -r '.trace_id // empty' "$job")
    TURN_PROJECT_ID=$(jq -r '.project_id // empty' "$job")
    TURN_ROOT_SPAN_ID=$(jq -r '.root_span_id // empty' "$job")
    TURN_TASK_SPAN_ID=$(jq -r '.task_span_id // empty' "$job")
    TURN_TRACE_START=$(jq -r '.trace_start // empty' "$job")
    TURN_TASK_START=$(jq -r '.task_start // empty' "$job")
    TURN_PROMPT=$(jq -r '.prompt // ""' "$job")
    TURN_OFFSET=$(jq -r '.offset // 0' "$job")
    TURN_END_OFFSET=$(jq -r '.end_offset // 0' "$job")
    TURN_INDEX=$(jq -r '.turn_index // 1' "$job")
    TURN_WORKSPACE=$(jq -r '.workspace // empty' "$job")
    TURN_TRANSCRIPT_PATH=$(jq -r '.transcript_path // empty' "$job")
    TURN_WORKSPACE_NAME=$(basename "$TURN_WORKSPACE" 2>/dev/null || echo "Claude Code")
    TURN_FALLBACK_OUTPUT="Completed"
    [ -z "$TURN_PROJECT_ID" ] && TURN_PROJECT_ID=$(get_cached_project_id)

    if [ -z "$TURN_TRACE_ID" ] || [ -z "$TURN_ROOT_SPAN_ID" ] || [ -z "$TURN_TASK_SPAN_ID" ]; then
        log "WARN" "Skipping malformed finalize job"
        return 0
    fi
    if [ -z "$TURN_TRANSCRIPT_PATH" ] || [ ! -f "$TURN_TRANSCRIPT_PATH" ]; then
        log "WARN" "Skipping finalize job: transcript missing"
        return 0
    fi

    finalize_turn_trace
    TURN_END_OFFSET=0
    log "INFO" "Recovered unfinalized turn: trace=$TURN_TRACE_ID session=$TURN_SESSION_ID"
    return 0
}

idle_since=$(date +%s)
while true; do
    qfile=$(ls -1 "$PENDING" 2>/dev/null | head -1)
    if [ -z "$qfile" ]; then
        if [ $(( $(date +%s) - idle_since )) -ge "$IDLE_EXIT_SECS" ]; then
            debug "Queue worker $$ idle; exiting"
            exit 0
        fi
        sleep 1
        continue
    fi
    idle_since=$(date +%s)

    src="$PENDING/$qfile"
    work="$PROCESSING/$qfile"
    mv "$src" "$work" 2>/dev/null || continue

    jtype=$(jq -r '.type // "span"' "$work" 2>/dev/null)
    if [ "$jtype" = "finalize" ]; then
        run_finalize_job "$work" || true
        rm -f "$work" 2>/dev/null
        continue
    fi

    project_id=$(jq -r '.project_id // empty' "$work" 2>/dev/null)
    if [ -z "$project_id" ]; then
        project_name=$(jq -r '.project_name // empty' "$work" 2>/dev/null)
        project_id=$(get_project_id "${project_name:-$PROJECT}") || project_id=""
    fi

    ok=1
    if [ -n "$project_id" ]; then
        span_json=$(jq -c '.span' "$work" 2>/dev/null)
        if [ -n "$span_json" ] && [ "$span_json" != "null" ]; then
            _http_insert_span "$project_id" "$span_json" && ok=0
        else
            log "WARN" "Dropping malformed queue file: $qfile"
            rm -f "$work" 2>/dev/null
            continue
        fi
    fi

    if [ "$ok" -eq 0 ]; then
        rm -f "$work" 2>/dev/null
        continue
    fi

    attempts=$(jq -r '.attempts // 0' "$work" 2>/dev/null)
    attempts=$(( ${attempts:-0} + 1 ))
    if [ "$attempts" -ge "$MAX_ATTEMPTS" ]; then
        log "WARN" "Dropping span after $attempts failed upload attempts: $qfile"
        rm -f "$work" 2>/dev/null
        continue
    fi
    tmp="$work.tmp"
    if jq -c --argjson a "$attempts" '.attempts = $a' "$work" > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$PENDING/$qfile" 2>/dev/null
        rm -f "$work" 2>/dev/null
    else
        rm -f "$tmp" 2>/dev/null
        mv -f "$work" "$PENDING/$qfile" 2>/dev/null
    fi
    # Back off so an unreachable endpoint doesn't hot-loop the queue.
    sleep $(( attempts * 2 ))
done
