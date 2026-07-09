#!/bin/bash
# Common utilities for Judgeval Claude Code tracing hooks

# Configuration
export LOG_FILE="$HOME/.claude/state/judgeval_hook.log"
export STATE_FILE="$HOME/.claude/state/judgeval_state.json"
export LOCK_DIR="$HOME/.claude/state/judgeval.lock.d"
export DEBUG="${JUDGEVAL_CC_DEBUG:-false}"
export API_KEY="${JUDGMENT_API_KEY}"
export ORG_ID="${JUDGMENT_ORG_ID}"
export PROJECT="${JUDGEVAL_CC_PROJECT:-claude-code}"
export API_URL="${JUDGMENT_API_URL:-https://api.judgmentlabs.ai}"

mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$STATE_FILE")"

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

# File Locking (mkdir-based, atomic on POSIX)
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

# State Management
load_state() {
    # A hook killed mid-write can leave a truncated file; feeding invalid
    # JSON into the read-modify-write cycle would cascade into a state wipe,
    # so fall back to a fresh object instead.
    if [ -f "$STATE_FILE" ] && jq -e 'type == "object"' "$STATE_FILE" >/dev/null 2>&1; then
        cat "$STATE_FILE" 2>/dev/null
    else
        [ -f "$STATE_FILE" ] && log "WARN" "State file invalid; starting from empty state"
        echo "{}"
    fi
}

save_state() {
    # Never persist an empty or invalid state: a failed/killed jq upstream
    # yields "" from command substitution, and writing it would wipe all
    # session state (including the cached project routing).
    if [ -z "$1" ] || ! echo "$1" | jq -e 'type == "object"' >/dev/null 2>&1; then
        log "ERROR" "Refusing to save empty/invalid state"
        return 1
    fi
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
    # Large values (prompts, serialized histories) must never be passed as
    # jq/curl argv (ARG_MAX); feed them through /dev/fd instead.
    save_state "$(echo "$state" | jq --arg k "$1" --rawfile v <(printf '%s' "$2") '.[$k] = $v')"
}

get_session_state() {
    load_state | jq -r ".sessions[\"$1\"].$2 // empty"
}

get_session_fields() {
    local session_id="$1"
    shift
    load_state | jq -r --arg s "$session_id" --args \
        '(.sessions[$s] // {}) as $x | [$ARGS.positional[] as $k | ($x[$k] // "")] | join("\u001f")' "$@"
}

set_session_state() {
    with_lock _set_session_state_unsafe "$1" "$2" "$3"
}

_set_session_state_unsafe() {
    local state
    state=$(load_state)
    save_state "$(echo "$state" | jq --arg s "$1" --arg k "$2" --rawfile v <(printf '%s' "$3") \
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
        state=$(echo "$state" | jq --arg s "$session_id" --arg k "$key" --rawfile v <(printf '%s' "$val") \
            '.sessions[$s] = (.sessions[$s] // {}) | .sessions[$s][$k] = $v')
        shift 2
    done
    save_state "$state"
}

clear_session_keys() {
    with_lock _clear_session_keys_unsafe "$@"
}

_clear_session_keys_unsafe() {
    local session_id="$1"
    shift
    local state
    state=$(load_state)
    save_state "$(echo "$state" | jq --arg s "$session_id" --args \
        'reduce $ARGS.positional[] as $k (.; del(.sessions[$s][$k]))' "$@")"
}

# API Operations
_build_otlp_payload() {
    local span_json="$1"
    jq -n --arg service_name "$PROJECT" --slurpfile span_f <(printf '%s\n' "$span_json") '$span_f[0] as $span | {
        resourceSpans: [{
            resource: { attributes: [
                { key: "service.name", value: { stringValue: $service_name } },
                { key: "telemetry.sdk.name", value: { stringValue: "judgeval" } },
                { key: "telemetry.sdk.version", value: { stringValue: "1.0.0" } }
            ]},
            scopeSpans: [{ scope: { name: "judgeval" }, spans: [$span] }]
        }]
    }'
}

insert_span() {
    local project_id="$1" span_json="$2"
    local otlp_payload resp http_code
    
    debug "Inserting span: $(echo "$span_json" | jq -c '.name' 2>/dev/null)"
    
    otlp_payload=$(_build_otlp_payload "$span_json")
    
    resp=$(printf '%s' "$otlp_payload" | curl -s -w "\n%{http_code}" \
        --max-time 5 \
        --connect-timeout 3 \
        -X POST \
        -H "Authorization: Bearer $API_KEY" \
        -H "X-Organization-Id: $ORG_ID" \
        -H "X-Project-Id: $project_id" \
        -H "Content-Type: application/json" \
        --data-binary @- \
        "$API_URL/otel/v1/traces" 2>&1)
    
    http_code=$(echo "$resp" | tail -1)
    
    if [[ "$http_code" =~ ^20[012]$ ]]; then
        debug "OTLP insert successful (HTTP $http_code)"
        echo "success"
        return 0
    fi
    
    log "WARN" "OTLP insert failed (HTTP $http_code)"
    echo "failed"
    return 1
}

# Alias for backward compatibility
insert_span_sync() {
    insert_span "$@"
}

# Project Resolution
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

# Time Utilities
get_time_nanos() {
    if command -v python3 &>/dev/null; then
        python3 -c "import time; print(int(time.time() * 1e9))"
    else
        echo "$(($(date +%s) * 1000000000))"
    fi
}

iso_to_nanos() {
    local ts="$1"
    [ -z "$ts" ] && { get_time_nanos; return; }
    
    if command -v python3 &>/dev/null; then
        local result
        result=$(python3 -c "
from datetime import datetime
try:
    ts = '${ts}'.replace('Z', '+00:00')
    print(int(datetime.fromisoformat(ts).timestamp() * 1e9))
except: print('')
" 2>/dev/null)
        [ -n "$result" ] && { echo "$result"; return; }
    fi
    get_time_nanos
}

detect_provider() {
    local model="$1"
    case "$model" in
        anthropic/*|claude-*) echo "anthropic" ;;
        openai/*|gpt-*) echo "openai" ;;
        google/*|gemini-*) echo "google" ;;
        meta-llama/*|llama-*) echo "meta" ;;
        */*) echo "openrouter" ;;
        *) echo "anthropic" ;;
    esac
}

# Span Building
build_otlp_span() {
    local trace_id="$1" span_id="$2" parent_span_id="$3" name="$4"
    local start_time="$6" end_time="$7" attributes_json="$8" update_id="${9:-0}"

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
        --slurpfile attributes_f <(printf '%s\n' "$attrs_with_update") \
        '$attributes_f[0] as $attributes | {
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

# Utilities
generate_uuid() { uuidgen | tr '[:upper:]' '[:lower:]'; }
generate_trace_id() {
    local trace_id
    trace_id=$(generate_uuid | sed 's/-//g' | head -c 32)
    while [ ${#trace_id} -lt 32 ]; do trace_id="${trace_id}0"; done
    echo "$trace_id"
}
generate_span_id() { generate_uuid | sed 's/-//g' | head -c 16; }
count_file_lines() {
    local file="$1"
    [ -n "$file" ] && [ -f "$file" ] || { echo 0; return; }
    awk 'END{print NR}' "$file" 2>/dev/null || echo 0
}
find_transcript_path() {
    local session_id="$1" provided="${2:-}"
    if [ -n "$provided" ] && [ -f "$provided" ]; then
        echo "$provided"
        return 0
    fi
    [ -z "$session_id" ] && return 1
    find "$HOME/.claude/projects" -name "${session_id}.jsonl" -type f 2>/dev/null | head -1
}
get_hostname() { hostname 2>/dev/null || echo "unknown"; }
get_username() { whoami 2>/dev/null || echo "unknown"; }
get_os() { uname -s 2>/dev/null || echo "unknown"; }
