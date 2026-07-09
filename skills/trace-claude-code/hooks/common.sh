#!/bin/bash
# Common utilities for Judgeval Claude Code tracing hooks

# Configuration
# Overridable for tests
export LOG_FILE="${JUDGEVAL_LOG_FILE:-$HOME/.claude/state/judgeval_hook.log}"
export STATE_FILE="${JUDGEVAL_STATE_FILE:-$HOME/.claude/state/judgeval_state.json}"
export LOCK_DIR="${JUDGEVAL_LOCK_DIR:-$HOME/.claude/state/judgeval.lock.d}"
export DEBUG="${JUDGEVAL_CC_DEBUG:-false}"
DEBUG_ON=""
[ "$(echo "$DEBUG" | tr '[:upper:]' '[:lower:]')" = "true" ] && DEBUG_ON=1
export API_KEY="${JUDGMENT_API_KEY}"
export ORG_ID="${JUDGMENT_ORG_ID}"
export PROJECT="${JUDGEVAL_CC_PROJECT:-claude-code}"
export API_URL="${JUDGMENT_API_URL:-https://api.judgmentlabs.ai}"

mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$STATE_FILE")"

# Logging
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [$1] $2" >> "$LOG_FILE"; }

debug() {
    [ -n "$DEBUG_ON" ] && log "DEBUG" "$1"
    return 0
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

get_session_state() {
    load_state | jq -r ".sessions[\"$1\"].$2 // empty"
}

# get_session_fields SESSION_ID key... — one state read for N keys.
# Output: values joined by the 0x1f unit separator, in argument order.
get_session_fields() {
    local sid="$1"; shift
    load_state | jq -r --arg s "$sid" --args \
        '(.sessions[$s] // {}) as $x | [$ARGS.positional[] as $k | ($x[$k] // "")] | join("\u001f")' "$@"
}

# clear_session_keys SESSION_ID key... — deletes keys instead of writing ""
clear_session_keys() {
    with_lock _clear_session_keys_unsafe "$@"
}

_clear_session_keys_unsafe() {
    local sid="$1"; shift
    local state
    state=$(load_state)
    save_state "$(echo "$state" | jq --arg s "$sid" --args \
        'reduce $ARGS.positional[] as $k (.; del(.sessions[$s][$k]))' "$@")"
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
    local state
    state=$(load_state)
    save_state "$(echo "$state" | jq --arg s "$session_id" --args '
        .sessions[$s] = (reduce range(0; ($ARGS.positional | length); 2) as $i (
            (.sessions[$s] // {});
            . + {($ARGS.positional[$i]): $ARGS.positional[$i + 1]}
        ))' "$@")"
}

# API Operations

# insert_spans_batch PROJECT_ID span_json... — all spans in ONE OTLP request.
# The Stop hook can emit 10-20 spans per turn; sequential curls would add
# seconds of latency before the user's next prompt.
# Spans per request: bounds payload size (an interrupted 40-llm-span sweep
# produced a multi-MB payload) while keeping request count low.
OTLP_CHUNK_SIZE=20

insert_spans_batch() {
    local project_id="$1"; shift
    [ $# -eq 0 ] && return 0
    local total=$# failed=0
    [ -n "$DEBUG_ON" ] && debug "Inserting $total span(s)"
    while [ $# -gt 0 ]; do
        local chunk=("${@:1:$OTLP_CHUNK_SIZE}")
        shift $(( $# < OTLP_CHUNK_SIZE ? $# : OTLP_CHUNK_SIZE ))
        _insert_span_chunk "$project_id" "${chunk[@]}" || failed=$((failed + ${#chunk[@]}))
    done
    if [ "$failed" -gt 0 ]; then
        log "WARN" "OTLP insert: $failed/$total spans failed"
        return 1
    fi
    [ -n "$DEBUG_ON" ] && debug "OTLP insert successful ($total spans)"
    return 0
}

_insert_span_chunk() {
    local project_id="$1"; shift
    local resp http_code
    # Payload travels via stdin, never argv: a large batch as a curl
    # argument fails exec entirely with "Argument list too long".
    resp=$(printf '%s\n' "$@" | jq -cs --arg service_name "$PROJECT" '{
        resourceSpans: [{
            resource: { attributes: [
                { key: "service.name", value: { stringValue: $service_name } },
                { key: "telemetry.sdk.name", value: { stringValue: "judgeval" } },
                { key: "telemetry.sdk.version", value: { stringValue: "1.0.0" } }
            ]},
            scopeSpans: [{ scope: { name: "judgeval" }, spans: . }]
        }]
    }' | curl -s -w "\n%{http_code}" \
        --max-time 15 \
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
        return 0
    fi
    log "WARN" "OTLP chunk insert failed (HTTP $http_code, $# spans)"
    return 1
}

# flush_span_batch PROJECT_ID — sends and clears the SPAN_BATCH array.
flush_span_batch() {
    insert_spans_batch "$1" "${SPAN_BATCH[@]}" || return 1
    SPAN_BATCH=()
    return 0
}

insert_span() {
    if insert_spans_batch "$1" "$2"; then
        echo "success"
        return 0
    fi
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

workspace_display_name() {
    local n
    n=$(basename "${1:-.}" 2>/dev/null || echo "")
    [ -z "$n" ] || [ "$n" = "." ] && n="Claude Code"
    echo "$n"
}

# build_root_span_attrs SESSION_ID WORKSPACE [OUTPUT] [EXTRA_JSON]
# Single builder for the session root span's attributes, used at creation
# (ensure_trace) and finalization (session_end) so the finalize update can
# never silently drop an attribute added at creation. EXTRA_JSON is a jq
# object merged in (e.g. cross-trace link attributes).
build_root_span_attrs() {
    local session_id="$1" workspace="$2" output="$3" extra="$4"
    [ -z "$extra" ] && extra="{}"
    build_otlp_attributes "$(jq -n \
        --arg input "Session: $(workspace_display_name "$workspace")" \
        --arg output "$output" \
        --arg session_id "$session_id" \
        --arg workspace "${workspace:-}" \
        --arg hostname "$(get_hostname)" \
        --arg username "$(get_username)" \
        --arg os "$(get_os)" \
        --argjson extra "$extra" \
        '{
            "judgment.span_kind": "task",
            "judgment.input": $input,
            "judgment.session_id": $session_id,
            "workspace": $workspace,
            "hostname": $hostname,
            "username": $username,
            "os": $os,
            "source": "claude-code"
        } + (if $output == "" then {} else {"judgment.output": $output} end) + $extra')"
}

# Cross-trace linkage for resumed sessions.
#
# A Claude Code session keeps its session id across --resume, but each
# resume starts a new trace. The platform navigates between related traces
# via judgment.link.* span attributes (link_source_* renders as an "up"
# reference to the trace this one came from). We remember each session'"'"'s
# last completed trace so the next trace'"'"'s root can point back at it.

record_completed_trace() {
    with_lock _record_completed_trace_unsafe "$1" "$2" "$3"
}

_record_completed_trace_unsafe() {
    local state now
    now=$(date +%s)
    state=$(load_state)
    save_state "$(echo "$state" | jq --arg s "$1" --arg t "$2" --arg r "$3" --argjson now "$now" \
        '.completed_sessions[$s] = {trace_id: $t, root_span_id: $r, ended_at: $now}
         | .completed_sessions |= with_entries(select(.value.ended_at > ($now - 604800)))')"
}

# get_previous_trace SESSION_ID -> "trace_id<US>root_span_id" (empty if none)
get_previous_trace() {
    load_state | jq -r --arg s "$1" \
        '.completed_sessions[$s] // empty | [.trace_id, .root_span_id] | join("\u001f")'
}

# previous_trace_link_attrs SESSION_ID -> jq object with judgment.link.source_*
# pointing at the session'"'"'s previous trace root, or {}
previous_trace_link_attrs() {
    local prev_trace prev_root
    IFS=$'\x1f' read -r prev_trace prev_root <<< "$(get_previous_trace "$1")"
    if [ -n "$prev_trace" ] && [ -n "$prev_root" ]; then
        jq -cn --arg t "$prev_trace" --arg r "$prev_root" \
            '{"judgment.link.source_trace_id": $t, "judgment.link.source_span_id": $r}'
    else
        echo "{}"
    fi
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

    local project_id trace_id span_id start_time attrs span
    project_id=$(get_project_id "$PROJECT") || { log "ERROR" "Failed to get project"; return 1; }

    trace_id=$(generate_uuid | sed 's/-//g' | head -c 32)
    while [ ${#trace_id} -lt 32 ]; do trace_id="${trace_id}0"; done
    span_id=$(generate_uuid | sed 's/-//g' | head -c 16)
    start_time=$(get_time_nanos)

    # Claim trace creation atomically: SessionStart and UserPromptSubmit can
    # race for the same session (back-to-back in -p mode); without the lock
    # both mint roots and one clobbers the other's state. The network post
    # happens OUTSIDE the lock — if the loser's post never happens, nothing
    # is lost, and if the winner's root post fails, SessionEnd re-posts the
    # root span with the same id.
    if ! with_lock _reserve_trace_unsafe "$session_id" "$trace_id" "$span_id" "$project_id" "$start_time" "$initial_offset" "$workspace"; then
        TRACE_ID=$(get_session_state "$session_id" "trace_id")
        [ -n "$TRACE_ID" ] && { debug "Trace already created by concurrent hook"; return 0; }
        log "ERROR" "Could not reserve trace for session $session_id"
        return 1
    fi

    local link_attrs
    link_attrs=$(previous_trace_link_attrs "$session_id")
    attrs=$(build_root_span_attrs "$session_id" "$workspace" "" "$link_attrs")
    span=$(build_otlp_span "$trace_id" "$span_id" "" "Claude Code: $(workspace_display_name "$workspace")" "task" "$start_time" "$start_time" "$attrs" 0)
    insert_span_sync "$project_id" "$span" >/dev/null || log "ERROR" "Root span post failed (will re-post at session end)"

    TRACE_ID="$trace_id"
    log "INFO" "Created trace: $trace_id (session=$session_id)"
    return 0
}

# Returns 1 if this session already has a trace (caller lost the race).
_reserve_trace_unsafe() {
    local sid="$1" tid="$2" rid="$3" pid="$4" st="$5" off="$6" ws="$7"
    local state existing
    state=$(load_state)
    existing=$(echo "$state" | jq -r --arg s "$sid" '.sessions[$s].trace_id // empty')
    [ -n "$existing" ] && return 1
    save_state "$(echo "$state" | jq --arg s "$sid" --arg tid "$tid" --arg rid "$rid" \
        --arg pid "$pid" --arg st "$st" --arg off "$off" --arg ws "$ws" \
        '.sessions[$s] = (.sessions[$s] // {}) + {trace_id: $tid, root_span_id: $rid,
          project_id: $pid, started: $st, transcript_offset: $off, workspace: $ws}')"
}



# Time Utilities
get_time_nanos() {
    if [ -z "$_NOW_NANOS_MEMO" ]; then
        if command -v python3 &>/dev/null; then
            _NOW_NANOS_MEMO=$(python3 -c "import time; print(int(time.time() * 1e9))")
        else
            _NOW_NANOS_MEMO="$(($(date +%s) * 1000000000))"
        fi
    fi
    echo "$_NOW_NANOS_MEMO"
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
