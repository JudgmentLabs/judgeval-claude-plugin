#!/bin/bash
###
# Common utilities for Judgeval Claude Code tracing hooks
# Uses OTLP HTTP/JSON format to export spans to Judgment Labs API
###

# Config
export LOG_FILE="$HOME/.claude/state/judgeval_hook.log"
export STATE_FILE="$HOME/.claude/state/judgeval_state.json"
export LOCK_DIR="$HOME/.claude/state/judgeval.lock.d"
export QUEUE_DIR="$HOME/.claude/state/judgeval_queue"
export DEBUG="${JUDGEVAL_CC_DEBUG:-false}"
export API_KEY="${JUDGMENT_API_KEY}"
export ORG_ID="${JUDGMENT_ORG_ID}"
export PROJECT="${JUDGEVAL_CC_PROJECT:-claude-code}"
export API_URL="${JUDGMENT_API_URL:-https://api.judgmentlabs.ai}"

mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$STATE_FILE")" "$QUEUE_DIR"

# Logging
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [$1] $2" >> "$LOG_FILE"; }

debug() {
    if [ "$(echo "$DEBUG" | tr '[:upper:]' '[:lower:]')" = "true" ]; then
        log "DEBUG" "$1"
    fi
}

tracing_enabled() {
    [ "$(echo "$TRACE_TO_JUDGEVAL" | tr '[:upper:]' '[:lower:]')" = "true" ]
}

check_requirements() {
    for cmd in jq curl; do
        if ! command -v "$cmd" &>/dev/null; then
            log "ERROR" "$cmd not installed"
            return 1
        fi
    done
    if [ -z "$API_KEY" ]; then
        log "ERROR" "JUDGMENT_API_KEY not set"
        return 1
    fi
    if [ -z "$ORG_ID" ]; then
        log "ERROR" "JUDGMENT_ORG_ID not set"
        return 1
    fi
    return 0
}

###
# File Locking - mkdir-based (atomic on all POSIX systems)
###

acquire_lock() {
    local timeout="${1:-5}"
    local count=0
    local max_attempts=$((timeout * 20))
    local lock_age
    
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        sleep 0.05
        count=$((count + 1))
        if [ "$count" -ge "$max_attempts" ]; then
            if [ -d "$LOCK_DIR" ]; then
                lock_age=$(( $(date +%s) - $(stat -f %m "$LOCK_DIR" 2>/dev/null || stat -c %Y "$LOCK_DIR" 2>/dev/null || echo 0) ))
                if [ "$lock_age" -gt 30 ]; then
                    rmdir "$LOCK_DIR" 2>/dev/null || true
                    continue
                fi
            fi
            log "WARN" "Lock timeout after ${timeout}s"
            return 1
        fi
    done
    echo "$$" > "$LOCK_DIR/pid" 2>/dev/null || true
    return 0
}

release_lock() {
    rm -f "$LOCK_DIR/pid" 2>/dev/null || true
    rmdir "$LOCK_DIR" 2>/dev/null || true
}

with_lock() {
    if ! acquire_lock 5; then
        return 1
    fi
    local ret=0
    "$@" || ret=$?
    release_lock
    return $ret
}

###
# State Management - Atomic operations
###

load_state() {
    if [ -f "$STATE_FILE" ]; then
        cat "$STATE_FILE" 2>/dev/null
    else
        echo "{}"
    fi
}

save_state() {
    local tmp_file="${STATE_FILE}.tmp.$$"
    echo "$1" > "$tmp_file"
    mv -f "$tmp_file" "$STATE_FILE"
}

get_state_value() {
    load_state | jq -r ".$1 // empty"
}

set_state_value() {
    with_lock _set_state_value_unsafe "$1" "$2"
}

_set_state_value_unsafe() {
    local state
    state=$(load_state)
    save_state "$(echo "$state" | jq --arg k "$1" --arg v "$2" '.[$k] = $v')"
}

get_session_state() {
    load_state | jq -r ".sessions[\"$1\"].$2 // empty"
}

set_session_state() {
    with_lock _set_session_state_unsafe "$1" "$2" "$3"
}

_set_session_state_unsafe() {
    local state
    state=$(load_state)
    save_state "$(echo "$state" | jq --arg s "$1" --arg k "$2" --arg v "$3" \
        '.sessions[$s] = (.sessions[$s] // {}) | .sessions[$s][$k] = $v')"
}

set_session_state_batch() {
    local session_id="$1"
    shift
    with_lock _set_session_state_batch_unsafe "$session_id" "$@"
}

_set_session_state_batch_unsafe() {
    local session_id="$1"
    shift
    local state key val
    state=$(load_state)
    while [ $# -ge 2 ]; do
        key="$1"
        val="$2"
        state=$(echo "$state" | jq --arg s "$session_id" --arg k "$key" --arg v "$val" \
            '.sessions[$s] = (.sessions[$s] // {}) | .sessions[$s][$k] = $v')
        shift 2
    done
    save_state "$state"
}

###
# API Operations
###

queue_span() {
    local project_id="$1" span_json="$2"
    local queue_file
    queue_file="$QUEUE_DIR/span_$(date +%s%N)_$$.json"
    jq -n --arg pid "$project_id" --argjson span "$span_json" '{project_id: $pid, span: $span}' > "$queue_file"
    debug "Queued span: $(echo "$span_json" | jq -c '.name')"
}

process_queue_background() {
    (
        exec >/dev/null 2>&1
        for queue_file in "$QUEUE_DIR"/span_*.json; do
            [ -f "$queue_file" ] || continue
            local data project_id span_json
            data=$(cat "$queue_file")
            project_id=$(echo "$data" | jq -r '.project_id')
            span_json=$(echo "$data" | jq -c '.span')
            if _insert_span_sync "$project_id" "$span_json"; then
                rm -f "$queue_file"
            fi
        done
    ) &
}

_insert_span_sync() {
    local project_id="$1" span_json="$2"
    local otlp_payload resp http_code
    otlp_payload=$(jq -n --arg service_name "$PROJECT" --argjson span "$span_json" '{
        resourceSpans: [{
            resource: { attributes: [
                { key: "service.name", value: { stringValue: $service_name } },
                { key: "telemetry.sdk.name", value: { stringValue: "judgeval" } },
                { key: "telemetry.sdk.version", value: { stringValue: "1.0.0" } }
            ]},
            scopeSpans: [{ scope: { name: "judgeval" }, spans: [$span] }]
        }]
    }')

    resp=$(curl -s -w "\n%{http_code}" -X POST \
        -H "Authorization: Bearer $API_KEY" \
        -H "X-Organization-Id: $ORG_ID" \
        -H "X-Project-Id: $project_id" \
        -H "Content-Type: application/json" \
        -d "$otlp_payload" \
        "$API_URL/otel/v1/traces" 2>&1)

    http_code=$(echo "$resp" | tail -1)
    [[ "$http_code" =~ ^20[012]$ ]]
}

insert_span() {
    local project_id="$1" span_json="$2" async="${3:-false}"
    debug "Inserting span: $(echo "$span_json" | jq -c '.name')"

    if [ "$async" = "true" ]; then
        queue_span "$project_id" "$span_json"
        process_queue_background
        echo "queued"
        return 0
    fi

    local otlp_payload resp http_code
    otlp_payload=$(jq -n --arg service_name "$PROJECT" --argjson span "$span_json" '{
        resourceSpans: [{
            resource: { attributes: [
                { key: "service.name", value: { stringValue: $service_name } },
                { key: "telemetry.sdk.name", value: { stringValue: "judgeval" } },
                { key: "telemetry.sdk.version", value: { stringValue: "1.0.0" } }
            ]},
            scopeSpans: [{ scope: { name: "judgeval" }, spans: [$span] }]
        }]
    }')

    resp=$(curl -s -w "\n%{http_code}" -X POST \
        -H "Authorization: Bearer $API_KEY" \
        -H "X-Organization-Id: $ORG_ID" \
        -H "X-Project-Id: $project_id" \
        -H "Content-Type: application/json" \
        -d "$otlp_payload" \
        "$API_URL/otel/v1/traces" 2>&1)

    http_code=$(echo "$resp" | tail -1)
    
    if [[ "$http_code" =~ ^20[012]$ ]]; then
        debug "OTLP insert successful (HTTP $http_code)"
        echo "success"
        return 0
    fi

    log "ERROR" "OTLP insert failed (HTTP $http_code)"
    return 1
}

###
# Project Resolution
###

get_project_id() {
    local name="$1"
    local cached_id
    cached_id=$(get_state_value "project_id")
    if [ -n "$cached_id" ]; then
        echo "$cached_id"
        return 0
    fi

    debug "Resolving project: $name"
    local resp pid

    resp=$(curl -sf -X POST \
        -H "Authorization: Bearer $API_KEY" \
        -H "X-Organization-Id: $ORG_ID" \
        -H "Content-Type: application/json" \
        -d "{\"project_name\": \"$name\"}" \
        "$API_URL/projects/resolve/" 2>/dev/null) || true

    pid=$(echo "$resp" | jq -r '.project_id // empty' 2>/dev/null)
    if [ -n "$pid" ]; then
        set_state_value "project_id" "$pid"
        echo "$pid"
        return 0
    fi

    debug "Creating project: $name"
    resp=$(curl -sf -X POST \
        -H "Authorization: Bearer $API_KEY" \
        -H "X-Organization-Id: $ORG_ID" \
        -H "Content-Type: application/json" \
        -d "{\"project_name\": \"$name\"}" \
        "$API_URL/projects/add/" 2>/dev/null) || true

    pid=$(echo "$resp" | jq -r '.project_id // empty' 2>/dev/null)
    if [ -n "$pid" ]; then
        set_state_value "project_id" "$pid"
        echo "$pid"
        return 0
    fi

    log "ERROR" "Failed to get or create project: $name"
    return 1
}

###
# Span Building
###

get_time_nanos() {
    if command -v python3 &>/dev/null; then
        python3 -c "import time; print(int(time.time() * 1e9))"
    else
        echo "$(($(date +%s) * 1000000000))"
    fi
}

build_otlp_span() {
    local trace_id="$1" span_id="$2" parent_span_id="$3" name="$4"
    local _kind="$5" start_time="$6" end_time="$7" attributes_json="$8"
    local update_id="${9:-0}"

    local attrs_with_update
    attrs_with_update=$(echo "$attributes_json" | jq --argjson uid "$update_id" \
        '. + [{"key": "judgment.update_id", "value": {"intValue": ($uid | tostring)}}]')

    jq -n \
        --arg trace_id "$trace_id" \
        --arg span_id "$span_id" \
        --arg parent_span_id "$parent_span_id" \
        --arg name "$name" \
        --arg start_time "$start_time" \
        --arg end_time "$end_time" \
        --argjson attributes "$attrs_with_update" \
        '{
            traceId: $trace_id,
            spanId: $span_id,
            parentSpanId: (if $parent_span_id == "" then null else $parent_span_id end),
            name: $name,
            kind: 1,
            startTimeUnixNano: $start_time,
            endTimeUnixNano: $end_time,
            attributes: $attributes,
            status: { code: 1 }
        } | with_entries(select(.value != null))'
}

build_otlp_attributes() {
    local kv_json="$1"
    echo "$kv_json" | jq '
        to_entries | map({
            key: .key,
            value: (
                if (.value | type) == "string" then { stringValue: .value }
                elif (.value | type) == "number" then
                    if (.value | floor) == .value then { intValue: (.value | tostring) }
                    else { doubleValue: .value }
                    end
                elif (.value | type) == "boolean" then { boolValue: .value }
                else { stringValue: (.value | tostring) }
                end
            )
        })
    '
}

###
# Utilities
###

generate_uuid() { uuidgen | tr '[:upper:]' '[:lower:]'; }
get_hostname() { hostname 2>/dev/null || echo "unknown"; }
get_username() { whoami 2>/dev/null || echo "unknown"; }
get_os() { uname -s 2>/dev/null || echo "unknown"; }
