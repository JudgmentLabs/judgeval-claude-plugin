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

# API Operations
_build_otlp_payload() {
    local span_json="$1"
    jq -n --arg service_name "$PROJECT" --argjson span "$span_json" '{
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
    
    resp=$(curl -s -w "\n%{http_code}" \
        --max-time 5 \
        --connect-timeout 3 \
        -X POST \
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
    
    log "WARN" "OTLP insert failed (HTTP $http_code)"
    echo "failed"
    return 1
}

# Alias for backward compatibility
insert_span_sync() {
    insert_span "$@"
}

# Project Resolution
_set_project_id_unsafe() {
    local state
    state=$(load_state)
    save_state "$(echo "$state" | jq --arg n "$1" --arg v "$2" '.project_ids[$n] = $v')"
}

get_project_id() {
    local name="$1"
    local cached_id
    # Cache is keyed by project name: different workspaces may trace to
    # different projects, so a single global cached id routes spans wrong.
    cached_id=$(load_state | jq -r --arg n "$name" '.project_ids[$n] // empty')
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
        with_lock _set_project_id_unsafe "$name" "$pid"
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
        with_lock _set_project_id_unsafe "$name" "$pid"
        echo "$pid"
        return 0
    fi

    log "ERROR" "Failed to get or create project: $name"
    return 1
}


# Per-Session Trace Lifecycle
#
# All trace state is keyed by the Claude Code session id. A single global
# current_trace_id breaks as soon as two sessions run concurrently: the
# second SessionStart overwrites the first session's trace, and whichever
# session ends first clears the pointer and silently un-traces the other.

clear_session_state() {
    with_lock _clear_session_state_unsafe "$1"
}

_clear_session_state_unsafe() {
    local state
    state=$(load_state)
    save_state "$(echo "$state" | jq --arg s "$1" 'del(.sessions[$s])')"
}

session_history_file() {
    echo "$HOME/.claude/state/judgeval_history_$1.json"
}

# ensure_trace SESSION_ID WORKSPACE [TRANSCRIPT_PATH]
# Idempotent: creates the trace + root span for a session if it doesn't
# exist yet, so any hook (not just SessionStart) can recover a session that
# was started before the plugin was installed or whose SessionStart failed.
# Sets TRACE_ID on success.
#
# The transcript may already contain lines when the trace is created (a
# resumed session, or a mid-session plugin install): those lines belong to
# earlier traces or to the untraced past, so parsing starts after them.
ensure_trace() {
    local session_id="$1" workspace="$2" transcript_path="$3"
    TRACE_ID=$(get_session_state "$session_id" "trace_id")
    [ -n "$TRACE_ID" ] && return 0

    local initial_offset=0
    if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
        initial_offset=$(awk 'END{print NR}' "$transcript_path" 2>/dev/null || echo 0)
        [ "$initial_offset" -gt 0 ] 2>/dev/null || initial_offset=0
        [ "$initial_offset" -gt 0 ] && debug "Trace starts at transcript line $initial_offset"
    fi

    local project_id trace_id span_id workspace_name start_time attrs span
    project_id=$(get_project_id "$PROJECT") || { log "ERROR" "Failed to get project"; return 1; }

    trace_id=$(generate_uuid | sed 's/-//g' | head -c 32)
    while [ ${#trace_id} -lt 32 ]; do trace_id="${trace_id}0"; done
    span_id=$(generate_uuid | sed 's/-//g' | head -c 16)
    workspace_name=$(basename "${workspace:-.}" 2>/dev/null || echo "Claude Code")
    [ -z "$workspace_name" ] || [ "$workspace_name" = "." ] && workspace_name="Claude Code"
    start_time=$(get_time_nanos)

    attrs=$(build_otlp_attributes "$(jq -n \
        --arg span_kind "task" \
        --arg input "Session: $workspace_name" \
        --arg session_id "$session_id" \
        --arg workspace "${workspace:-}" \
        --arg hostname "$(get_hostname)" \
        --arg username "$(get_username)" \
        --arg os "$(get_os)" \
        '{
            "judgment.span_kind": $span_kind,
            "judgment.input": $input,
            "judgment.session_id": $session_id,
            "workspace": $workspace,
            "hostname": $hostname,
            "username": $username,
            "os": $os,
            "source": "claude-code"
        }')")

    span=$(build_otlp_span "$trace_id" "$span_id" "" "Claude Code: $workspace_name" "task" "$start_time" "$start_time" "$attrs" 0)
    insert_span_sync "$project_id" "$span" >/dev/null || { log "ERROR" "Failed to create session root"; return 1; }

    set_session_state_batch "$session_id" \
        "trace_id" "$trace_id" \
        "root_span_id" "$span_id" \
        "project_id" "$project_id" \
        "workspace_name" "$workspace_name" \
        "workspace" "${workspace:-}" \
        "started" "$start_time" \
        "transcript_offset" "$initial_offset"

    TRACE_ID="$trace_id"
    log "INFO" "Created trace: $trace_id (session=$session_id)"
    return 0
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

# Utilities
generate_uuid() { uuidgen | tr '[:upper:]' '[:lower:]'; }
get_hostname() { hostname 2>/dev/null || echo "unknown"; }
get_username() { whoami 2>/dev/null || echo "unknown"; }
get_os() { uname -s 2>/dev/null || echo "unknown"; }
