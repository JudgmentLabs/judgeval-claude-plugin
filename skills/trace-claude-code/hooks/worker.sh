#!/bin/bash
###
# Background queue worker - all span building and network I/O happens here.
#
# Hooks never build OTLP payloads or touch the network; they enqueue small
# job files under $QUEUE_DIR/pending/ and spawn this worker. One worker runs
# at a time (pid-file lock). It drains the queue oldest-first and exits after
# a period with nothing to do; the next enqueue respawns it. All network
# calls are time-bounded.
#
# Job types:
#   span                - upload one already-built span      (network, retried)
#   turn_start          - build + enqueue root/Task spans    (local build)
#   notification_attach - build subagent-result marker and
#                         parent extension spans             (local build)
#   relay_attach        - build the task-notification relay
#                         LLM span and parent updates        (local build)
#   finalize            - parse a turn's transcript slice
#                         and enqueue its spans              (local build)
#   subagent            - process a SubagentStop event       (local build,
#                         retried until parent trace exists)
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

jf() { jq -r --arg k "$1" '.[$k] // empty' "$2" 2>/dev/null; }

# --- turn_start: build and enqueue the turn's root and Task spans ---
run_turn_start_job() {
    local job="$1"
    local project_id session_id trace_id root_span_id task_span_id start_time
    local prompt workspace workspace_name host user os turn_index prompt_json
    project_id=$(jf project_id "$job"); session_id=$(jf session_id "$job")
    trace_id=$(jf trace_id "$job"); root_span_id=$(jf root_span_id "$job")
    task_span_id=$(jf task_span_id "$job"); start_time=$(jf start_time "$job")
    prompt=$(jf prompt "$job"); workspace=$(jf workspace "$job")
    workspace_name=$(jf workspace_name "$job"); host=$(jf hostname "$job")
    user=$(jf username "$job"); os=$(jf os "$job"); turn_index=$(jf turn_index "$job")

    [ -n "$trace_id" ] && [ -n "$root_span_id" ] && [ -n "$task_span_id" ] || {
        log "WARN" "Skipping malformed turn_start job"; return 0; }

    prompt_json=$(printf '%s' "$prompt" | jq -Rs '.')

    local root_attrs task_attrs root_span task_span
    root_attrs=$(build_otlp_attributes "$(jq -n \
        --arg span_kind "task" \
        --slurpfile input_f <(printf '%s\n' "$prompt_json") \
        --arg session_id "$session_id" \
        --arg workspace "$workspace" \
        --arg hostname "$host" \
        --arg username "$user" \
        --arg os "$os" \
        --argjson turn_index "${turn_index:-1}" \
        '$input_f[0] as $input | {
            "judgment.span_kind": $span_kind,
            "judgment.input": $input,
            "judgment.output": "",
            "judgment.session_id": $session_id,
            "session_id": $session_id,
            "turn_index": $turn_index,
            "workspace": $workspace,
            "hostname": $hostname,
            "username": $username,
            "os": $os,
            "source": "claude-code"
        }')"
    )
    root_span=$(build_otlp_span "$trace_id" "$root_span_id" "" "Claude Code Turn: ${workspace_name:-Claude Code}" "task" "$start_time" "$start_time" "$root_attrs" 0)
    insert_span "$project_id" "$root_span" >/dev/null

    task_attrs=$(build_otlp_attributes "$(jq -n \
        --arg span_kind "task" \
        --slurpfile input_f <(printf '%s\n' "$prompt_json") \
        --arg session_id "$session_id" \
        --argjson turn_index "${turn_index:-1}" \
        '$input_f[0] as $input | {
            "judgment.span_kind": $span_kind,
            "judgment.input": $input,
            "judgment.output": "",
            "judgment.session_id": $session_id,
            "session_id": $session_id,
            "turn_index": $turn_index
        }')"
    )
    task_span=$(build_otlp_span "$trace_id" "$task_span_id" "$root_span_id" "Task" "task" "$start_time" "$start_time" "$task_attrs" 0)
    insert_span "$project_id" "$task_span" >/dev/null
    return 0
}

# --- subagent_start: placeholder container span, visible while it runs ---
run_subagent_start_job() {
    local job="$1"
    local project_id trace_id span_id parent_span_id agent_id agent_type start_time session_id turn_index
    project_id=$(jf project_id "$job"); trace_id=$(jf trace_id "$job")
    span_id=$(jf span_id "$job"); parent_span_id=$(jf parent_span_id "$job")
    agent_id=$(jf agent_id "$job"); agent_type=$(jf agent_type "$job")
    start_time=$(jf start_time "$job"); session_id=$(jf session_id "$job")
    turn_index=$(jf turn_index "$job")

    [ -n "$trace_id" ] && [ -n "$span_id" ] && [ -n "$parent_span_id" ] || {
        log "WARN" "Skipping malformed subagent_start job"; return 0; }

    local input_json attrs span
    input_json=$(printf '%s' "${agent_type:-Subagent task}" | jq -Rs '.')
    attrs=$(build_otlp_attributes "$(jq -n \
        --arg span_kind "task" \
        --slurpfile input_f <(printf '%s\n' "$input_json") \
        --arg subagent_id "$agent_id" \
        --arg agent_type "$agent_type" \
        --arg session_id "$session_id" \
        --argjson turn_index "${turn_index:-1}" \
        '$input_f[0] as $input | {
            "judgment.span_kind": $span_kind,
            "judgment.input": $input,
            "judgment.output": "",
            "subagent_id": $subagent_id,
            "agent_type": $agent_type,
            "judgment.session_id": $session_id,
            "session_id": $session_id,
            "turn_index": $turn_index
        }')"
    )
    span=$(build_otlp_span "$trace_id" "$span_id" "$parent_span_id" "Subagent: $agent_id" "task" "$start_time" "$start_time" "$attrs" 0)
    insert_span "$project_id" "$span" >/dev/null
    return 0
}

# --- notification_attach: subagent-result marker + parent span extensions ---
run_notification_attach_job() {
    local job="$1"
    local project_id trace_id span_id root_span_id task_span_id now session_id
    local task_id bg_session description notification status summary output_file result
    local turn_index extend trace_start task_start parent_end
    local parent_input_json parent_output_json parent_llm parent_tools
    local workspace workspace_name host user os
    project_id=$(jf project_id "$job"); trace_id=$(jf trace_id "$job")
    span_id=$(jf span_id "$job"); root_span_id=$(jf root_span_id "$job")
    task_span_id=$(jf task_span_id "$job"); now=$(jf now "$job")
    session_id=$(jf session_id "$job"); task_id=$(jf task_id "$job")
    bg_session=$(jf background_session_id "$job"); description=$(jf description "$job")
    notification=$(jf notification "$job"); status=$(jf status "$job")
    summary=$(jf summary "$job"); output_file=$(jf output_file "$job")
    result=$(jf result "$job"); turn_index=$(jf turn_index "$job")
    extend=$(jf extend_parent "$job"); trace_start=$(jf trace_start "$job")
    task_start=$(jf task_start "$job"); parent_end=$(jf parent_end "$job")
    parent_input_json=$(jf parent_task_input_json "$job")
    parent_output_json=$(jf parent_task_output_json "$job")
    parent_llm=$(jf parent_llm_calls "$job"); parent_tools=$(jf parent_tool_calls "$job")
    workspace=$(jf workspace "$job"); workspace_name=$(jf workspace_name "$job")
    host=$(jf hostname "$job"); user=$(jf username "$job"); os=$(jf os "$job")

    [ -n "$trace_id" ] && [ -n "$task_span_id" ] && [ -n "$span_id" ] || {
        log "WARN" "Skipping malformed notification_attach job"; return 0; }

    local input_json output_json attrs span
    input_json=$(jq -cn \
        --arg task_id "$task_id" \
        --arg background_session_id "$bg_session" \
        --arg description "${description:-Subagent task}" \
        --rawfile notification <(printf '%s' "$notification") \
        '{task_id: $task_id, background_session_id: $background_session_id, description: $description, notification: $notification}' | jq -c '.' | jq -Rs '.')
    output_json=$(jq -cn \
        --arg status "${status:-completed}" \
        --arg summary "$summary" \
        --arg output_file "$output_file" \
        --rawfile result <(printf '%s' "$result") \
        '{status: $status, summary: $summary, output_file: $output_file, result: $result}' | jq -c '.' | jq -Rs '.')
    attrs=$(build_otlp_attributes "$(jq -n \
        --arg span_kind "task" \
        --slurpfile input_f <(printf '%s\n' "$input_json") \
        --slurpfile output_f <(printf '%s\n' "$output_json") \
        --arg task_id "$task_id" \
        --arg background_session_id "$bg_session" \
        --arg session_id "$session_id" \
        --argjson turn_index "${turn_index:-1}" \
        '$input_f[0] as $input | $output_f[0] as $output | {
          "judgment.span_kind": $span_kind,
          "judgment.input": $input,
          "judgment.output": $output,
          "subagent_task_id": $task_id,
          "background_session_id": $background_session_id,
          "judgment.session_id": $session_id,
          "session_id": $session_id,
          "turn_index": $turn_index
        }')"
    )
    span=$(build_otlp_span "$trace_id" "$span_id" "$task_span_id" "Subagent Result: ${summary:-$task_id}" "task" "$now" "$now" "$attrs" 20)
    insert_span "$project_id" "$span" >/dev/null

    if [ "$extend" = "true" ] && [ -n "$parent_input_json" ] && [ -n "$parent_output_json" ]; then
        local update_id parent_task_attrs parent_task_span parent_root_attrs parent_root_span
        if command -v python3 >/dev/null 2>&1; then
            update_id=$(python3 -c 'import time; print(int(time.time() * 1000))' 2>/dev/null || echo 30)
        else
            update_id=30
        fi
        parent_task_attrs=$(build_otlp_attributes "$(jq -n \
            --arg span_kind "task" \
            --slurpfile input_f <(printf '%s\n' "$parent_input_json") \
            --slurpfile output_f <(printf '%s\n' "$parent_output_json") \
            --argjson llm "${parent_llm:-0}" \
            --argjson tools "${parent_tools:-0}" \
            --arg session_id "$session_id" \
            --argjson turn_index "${turn_index:-1}" \
            '$input_f[0] as $input | $output_f[0] as $output | {
              "judgment.span_kind": $span_kind,
              "judgment.input": $input,
              "judgment.output": $output,
              "llm_call_count": $llm,
              "tool_count": $tools,
              "judgment.session_id": $session_id,
              "session_id": $session_id,
              "turn_index": $turn_index
            }')"
        )
        parent_task_span=$(build_otlp_span "$trace_id" "$task_span_id" "$root_span_id" "Task" "task" "$task_start" "$parent_end" "$parent_task_attrs" "$update_id")
        insert_span "$project_id" "$parent_task_span" >/dev/null

        parent_root_attrs=$(build_otlp_attributes "$(jq -n \
            --arg span_kind "task" \
            --slurpfile input_f <(printf '%s\n' "$parent_input_json") \
            --slurpfile output_f <(printf '%s\n' "$parent_output_json") \
            --arg session_id "$session_id" \
            --arg workspace "$workspace" \
            --arg hostname "$host" \
            --arg username "$user" \
            --arg os "$os" \
            --argjson turn_index "${turn_index:-1}" \
            '$input_f[0] as $input | $output_f[0] as $output | {
              "judgment.span_kind": $span_kind,
              "judgment.input": $input,
              "judgment.output": $output,
              "judgment.session_id": $session_id,
              "session_id": $session_id,
              "turn_index": $turn_index,
              "workspace": $workspace,
              "hostname": $hostname,
              "username": $username,
              "os": $os,
              "source": "claude-code"
            }')"
        )
        parent_root_span=$(build_otlp_span "$trace_id" "$root_span_id" "" "Claude Code Turn: ${workspace_name:-Claude Code}" "task" "$trace_start" "$parent_end" "$parent_root_attrs" "$update_id")
        insert_span "$project_id" "$parent_root_span" >/dev/null
    fi
    log "INFO" "Subagent task notification attached: task=$task_id trace=$trace_id session=$session_id"
    return 0
}

# --- relay_attach: task-notification follow-up LLM span + parent updates ---
run_relay_attach_job() {
    local job="$1"
    local session_id parent_session trace_id project_id root_span_id task_span_id
    local trace_start task_start turn_index task_id notification last_assistant
    local parent_input_json parent_output_json parent_llm parent_tools
    local workspace workspace_name host user os transcript_path
    session_id=$(jf session_id "$job"); parent_session=$(jf parent_session_id "$job")
    trace_id=$(jf trace_id "$job"); project_id=$(jf project_id "$job")
    root_span_id=$(jf root_span_id "$job"); task_span_id=$(jf task_span_id "$job")
    trace_start=$(jf trace_start "$job"); task_start=$(jf task_start "$job")
    turn_index=$(jf turn_index "$job"); task_id=$(jf task_id "$job")
    notification=$(jf notification "$job"); last_assistant=$(jf last_assistant "$job")
    parent_input_json=$(jf parent_task_input_json "$job")
    parent_output_json=$(jf parent_task_output_json "$job")
    parent_llm=$(jf parent_llm_calls "$job"); parent_tools=$(jf parent_tool_calls "$job")
    workspace=$(jf workspace "$job"); workspace_name=$(jf workspace_name "$job")
    host=$(jf hostname "$job"); user=$(jf username "$job"); os=$(jf os "$job")
    transcript_path=$(jf transcript_path "$job")

    [ -n "$trace_id" ] && [ -n "$root_span_id" ] && [ -n "$task_span_id" ] && [ -n "$parent_session" ] || {
        log "WARN" "Skipping malformed relay_attach job"; return 0; }
    [ -n "$last_assistant" ] || return 0

    local relay_record request_id request_start_iso request_end_iso relay_start relay_end
    relay_record=""
    if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
        relay_record=$(jq -c --rawfile out <(printf '%s' "$last_assistant") '
            select(.type == "assistant")
            | ([.message.content[]? | select(.type == "text") | .text] | join("\n")) as $text
            | select($text == $out)
        ' "$transcript_path" 2>/dev/null | tail -1)
    fi
    request_id=$(echo "$relay_record" | jq -r '.requestId // empty' 2>/dev/null)
    request_end_iso=$(echo "$relay_record" | jq -r '.timestamp // empty' 2>/dev/null)
    request_start_iso=""
    if [ -n "$request_id" ] && [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
        request_start_iso=$(jq -rs --arg req "$request_id" '
            (map(.requestId // "") | index($req)) as $i
            | if $i == null or $i == 0 then empty
              else (.[0:$i] | map(.timestamp // empty | select(length > 0)) | last) // empty
              end
        ' "$transcript_path" 2>/dev/null)
    fi
    [ -z "$request_start_iso" ] && request_start_iso="$request_end_iso"
    relay_end=$(iso_to_nanos "$request_end_iso")
    relay_start=$(iso_to_nanos "$request_start_iso")
    if [ "$relay_start" -gt "$relay_end" ] 2>/dev/null; then
        relay_start="$relay_end"
    fi

    local model usage inp out cc cr usage_meta provider update_id span_id
    model=$(echo "$relay_record" | jq -r '.message.model // .model // empty' 2>/dev/null)
    [ -z "$model" ] && model="claude"
    usage=$(echo "$relay_record" | jq -c '.message.usage // .usage // {}' 2>/dev/null)
    [ -z "$usage" ] || [ "$usage" = "null" ] && usage="{}"
    inp=$(echo "$usage" | jq -r '.input_tokens // 0' 2>/dev/null)
    out=$(echo "$usage" | jq -r '.output_tokens // 0' 2>/dev/null)
    cc=$(echo "$usage" | jq -r '.cache_creation_input_tokens // 0' 2>/dev/null)
    cr=$(echo "$usage" | jq -r '.cache_read_input_tokens // 0' 2>/dev/null)
    usage_meta=$(jq -n --argjson inp "${inp:-0}" --argjson out "${out:-0}" \
        --argjson cc "${cc:-0}" --argjson cr "${cr:-0}" \
        '{input_tokens: $inp, output_tokens: $out, cache_creation_input_tokens: $cc, cache_read_input_tokens: $cr}' | jq -c '.')

    local messages_json input_payload output_payload input_json output_json attrs span
    messages_json=$(jq -cn \
        --rawfile notification <(printf '%s' "${notification:-Task notification}") \
        --rawfile response <(printf '%s' "$last_assistant") \
        --arg end "$relay_end" \
        '[
          {role: "user", content: [{type: "text", text: $notification}], text: $notification},
          {role: "assistant", timestamp_nanos: $end, content: [{type: "text", text: $response}], text: $response}
        ]')
    input_payload=$(jq -cn \
        --arg session_id "$parent_session" \
        --arg trace_id "$trace_id" \
        --arg root_span_id "$root_span_id" \
        --arg task_span_id "$task_span_id" \
        --argjson turn_index "${turn_index:-1}" \
        --arg workspace "$workspace" \
        --rawfile notification <(printf '%s' "${notification:-Task notification}") \
        '{
          metadata: {
            session_id: $session_id, trace_id: $trace_id,
            root_span_id: $root_span_id, task_span_id: $task_span_id,
            turn_index: $turn_index, workspace: $workspace, source: "claude-code"
          },
          current_user_prompt: "task-notification",
          messages: [{role: "user", content: [{type: "text", text: $notification}], text: $notification}]
        }')
    output_payload=$(echo "$input_payload" | jq --slurpfile messages_f <(printf '%s\n' "$messages_json") --rawfile response <(printf '%s' "$last_assistant") \
        '.messages = $messages_f[0] | .assistant_output = $response')
    input_json=$(echo "$input_payload" | jq -c '.' | jq -Rs '.')
    output_json=$(echo "$output_payload" | jq -c '.' | jq -Rs '.')
    provider=$(detect_provider "$model")
    if command -v python3 >/dev/null 2>&1; then
        update_id=$(python3 -c 'import time; print(int(time.time() * 1000))' 2>/dev/null || echo 30)
    else
        update_id=30
    fi
    span_id=$(generate_span_id)

    attrs=$(build_otlp_attributes "$(jq -n \
        --arg span_kind "llm" \
        --slurpfile input_f <(printf '%s\n' "$input_json") \
        --slurpfile output_f <(printf '%s\n' "$output_json") \
        --arg model "$model" \
        --arg provider "$provider" \
        --argjson prompt "${inp:-0}" \
        --argjson completion "${out:-0}" \
        --argjson cache_create "${cc:-0}" \
        --argjson cache_read "${cr:-0}" \
        --arg usage_meta "$usage_meta" \
        --arg session_id "$parent_session" \
        --argjson turn_index "${turn_index:-1}" \
        '$input_f[0] as $input | $output_f[0] as $output | {
          "judgment.span_kind": $span_kind,
          "judgment.input": $input,
          "judgment.output": $output,
          "judgment.llm.provider": $provider,
          "judgment.llm.model": $model,
          "judgment.usage.non_cached_input_tokens": $prompt,
          "judgment.usage.output_tokens": $completion,
          "judgment.usage.cache_creation_input_tokens": $cache_create,
          "judgment.usage.cache_read_input_tokens": $cache_read,
          "judgment.usage.metadata": $usage_meta,
          "judgment.session_id": $session_id,
          "session_id": $session_id,
          "turn_index": $turn_index
        }')"
    )
    span=$(build_otlp_span "$trace_id" "$span_id" "$task_span_id" "$model" "llm" "$relay_start" "$relay_end" "$attrs" "$update_id")
    insert_span "$project_id" "$span" >/dev/null

    if [ -n "$parent_input_json" ] && [ -n "$parent_output_json" ] &&
       [ -n "$trace_start" ] && [ -n "$task_start" ] &&
       echo "$parent_input_json" | jq -e 'type == "string"' >/dev/null 2>&1 &&
       echo "$parent_output_json" | jq -e 'type == "string"' >/dev/null 2>&1; then
        local updated_output_json updated_llm_calls parent_end parent_task_attrs parent_task_span parent_root_attrs parent_root_span root_name
        updated_output_json=$(echo "$parent_output_json" | jq -r '.' 2>/dev/null | jq -c --rawfile response <(printf '%s' "$last_assistant") --arg end "$relay_end" \
            '.messages += [{role: "assistant", timestamp_nanos: $end, content: [{type: "text", text: $response}], text: $response}]
             | .assistant_output = $response' 2>/dev/null | jq -Rs 'rtrimstr("\n")')
        [ -z "$updated_output_json" ] && updated_output_json="$parent_output_json"
        updated_llm_calls=$(( ${parent_llm:-0} + 1 ))
        parent_end="$relay_end"

        parent_task_attrs=$(build_otlp_attributes "$(jq -n \
            --arg span_kind "task" \
            --slurpfile input_f <(printf '%s\n' "$parent_input_json") \
            --slurpfile output_f <(printf '%s\n' "$updated_output_json") \
            --argjson llm "$updated_llm_calls" \
            --argjson tools "${parent_tools:-0}" \
            --arg session_id "$parent_session" \
            --argjson turn_index "${turn_index:-1}" \
            '$input_f[0] as $input | $output_f[0] as $output | {
              "judgment.span_kind": $span_kind,
              "judgment.input": $input,
              "judgment.output": $output,
              "llm_call_count": $llm,
              "tool_count": $tools,
              "judgment.session_id": $session_id,
              "session_id": $session_id,
              "turn_index": $turn_index
            }')"
        )
        parent_task_span=$(build_otlp_span "$trace_id" "$task_span_id" "$root_span_id" "Task" "task" "$task_start" "$parent_end" "$parent_task_attrs" "$update_id")
        insert_span "$project_id" "$parent_task_span" >/dev/null

        parent_root_attrs=$(build_otlp_attributes "$(jq -n \
            --arg span_kind "task" \
            --slurpfile input_f <(printf '%s\n' "$parent_input_json") \
            --slurpfile output_f <(printf '%s\n' "$updated_output_json") \
            --arg session_id "$parent_session" \
            --arg workspace "$workspace" \
            --arg hostname "$host" \
            --arg username "$user" \
            --arg os "$os" \
            --argjson turn_index "${turn_index:-1}" \
            '$input_f[0] as $input | $output_f[0] as $output | {
              "judgment.span_kind": $span_kind,
              "judgment.input": $input,
              "judgment.output": $output,
              "judgment.session_id": $session_id,
              "session_id": $session_id,
              "turn_index": $turn_index,
              "workspace": $workspace,
              "hostname": $hostname,
              "username": $username,
              "os": $os,
              "source": "claude-code"
            }')"
        )
        root_name="Claude Code Turn: ${workspace_name:-Claude Code}"
        parent_root_span=$(build_otlp_span "$trace_id" "$root_span_id" "" "$root_name" "task" "$trace_start" "$parent_end" "$parent_root_attrs" "$update_id")
        insert_span "$project_id" "$parent_root_span" >/dev/null

        if [ -n "$task_id" ]; then
            set_session_state_batch "subagent:$task_id" \
                "parent_trace_end" "$parent_end" \
                "parent_task_output_json" "$updated_output_json" \
                "parent_llm_calls" "$updated_llm_calls"
        fi
    fi
    log "INFO" "Task-notification follow-up attached: trace=$trace_id session=$parent_session"
    return 0
}

# --- finalize: parse a turn's transcript slice and enqueue its spans ---
run_finalize_job() {
    local job="$1"
    TURN_SESSION_ID=$(jf session_id "$job")
    TURN_TRACE_ID=$(jf trace_id "$job")
    TURN_PROJECT_ID=$(jf project_id "$job")
    TURN_ROOT_SPAN_ID=$(jf root_span_id "$job")
    TURN_TASK_SPAN_ID=$(jf task_span_id "$job")
    TURN_TRACE_START=$(jf trace_start "$job")
    TURN_TASK_START=$(jf task_start "$job")
    TURN_PROMPT=$(jf prompt "$job")
    TURN_OFFSET=$(jq -r '.offset // 0' "$job" 2>/dev/null)
    TURN_END_OFFSET=$(jq -r '.end_offset // 0' "$job" 2>/dev/null)
    TURN_INDEX=$(jq -r '.turn_index // 1' "$job" 2>/dev/null)
    TURN_WORKSPACE=$(jf workspace "$job")
    TURN_TRANSCRIPT_PATH=$(jf transcript_path "$job")
    TURN_WORKSPACE_NAME=$(basename "$TURN_WORKSPACE" 2>/dev/null || echo "Claude Code")
    TURN_FALLBACK_OUTPUT=$(jf last_assistant "$job")
    [ -z "$TURN_FALLBACK_OUTPUT" ] && TURN_FALLBACK_OUTPUT="Completed"
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

    # Refresh the durable parent snapshots that async subagent notifications
    # and follow-ups attach to (previously done inline in the Stop hook).
    local hostname_v username_v os_v subagent_key
    hostname_v=$(get_hostname); username_v=$(get_username); os_v=$(get_os)
    while IFS= read -r subagent_key; do
        [ -z "$subagent_key" ] && continue
        set_session_state_batch "$subagent_key" \
            "trace_start" "${TURN_TRACE_START:-}" \
            "task_start" "${TURN_TASK_START:-}" \
            "parent_trace_end" "${TURN_FINAL_END:-}" \
            "parent_task_input_json" "${TURN_TASK_INPUT_ATTR_JSON:-}" \
            "parent_task_output_json" "${TURN_TASK_OUTPUT_ATTR_JSON:-}" \
            "parent_llm_calls" "${TURN_LLM_CALLS:-0}" \
            "parent_tool_calls" "${TURN_TOOL_CALLS:-0}" \
            "parent_workspace" "${TURN_WORKSPACE:-}" \
            "parent_workspace_name" "${TURN_WORKSPACE_NAME:-Claude Code}" \
            "parent_hostname" "$hostname_v" \
            "parent_username" "$username_v" \
            "parent_os" "$os_v"
    done < <(load_state | jq -r --arg trace "$TURN_TRACE_ID" '
        .sessions
        | to_entries[]
        | select(.key | startswith("subagent:"))
        | select(.value.trace_id == $trace)
        | .key
    ')

    TURN_END_OFFSET=0
    log "INFO" "Trace finalized: $TURN_TRACE_ID (session=$TURN_SESSION_ID, turn=${TURN_INDEX:-1}, llm=$TURN_LLM_CALLS, tools=$TURN_TOOL_CALLS)"
    return 0
}

# --- subagent: replay a SubagentStop event through the processing body ---
# Exit 3 from the processor means the parent trace context does not exist
# yet (a sync subagent whose turn finalize job is behind us in the queue);
# retry so the finalize job runs first.
run_subagent_job() {
    local job="$1" rc=0
    jq -r '.input // empty' "$job" 2>/dev/null | bash "$SCRIPT_DIR/subagent_stop.sh" --judgeval-process || rc=$?
    [ "$rc" -eq 3 ] && return 3
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

    ok=1
    case "$jtype" in
        finalize)
            run_finalize_job "$work" || true
            rm -f "$work" 2>/dev/null
            continue
            ;;
        turn_start)
            run_turn_start_job "$work" || true
            rm -f "$work" 2>/dev/null
            continue
            ;;
        subagent_start)
            run_subagent_start_job "$work" || true
            rm -f "$work" 2>/dev/null
            continue
            ;;
        notification_attach)
            run_notification_attach_job "$work" || true
            rm -f "$work" 2>/dev/null
            continue
            ;;
        relay_attach)
            run_relay_attach_job "$work" || true
            rm -f "$work" 2>/dev/null
            continue
            ;;
        subagent)
            if run_subagent_job "$work"; then
                rm -f "$work" 2>/dev/null
                continue
            fi
            # parent trace context not ready yet: fall through to retry
            ;;
        span)
            project_id=$(jq -r '.project_id // empty' "$work" 2>/dev/null)
            if [ -z "$project_id" ]; then
                project_name=$(jq -r '.project_name // empty' "$work" 2>/dev/null)
                project_id=$(get_project_id "${project_name:-$PROJECT}") || project_id=""
            fi
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
            ;;
        *)
            log "WARN" "Dropping unknown queue job type '$jtype': $qfile"
            rm -f "$work" 2>/dev/null
            continue
            ;;
    esac

    attempts=$(jq -r '.attempts // 0' "$work" 2>/dev/null)
    attempts=$(( ${attempts:-0} + 1 ))
    if [ "$attempts" -ge "$MAX_ATTEMPTS" ]; then
        log "WARN" "Dropping job after $attempts failed attempts: $qfile"
        rm -f "$work" 2>/dev/null
        continue
    fi
    tmp="$work.tmp"
    if jq -c --argjson a "$attempts" '.attempts = $a' "$work" > "$tmp" 2>/dev/null; then
        # requeue under a fresh (later) name so other jobs are not blocked
        mv -f "$tmp" "$PENDING/$(get_time_nanos)-$$-$RANDOM.json" 2>/dev/null
        rm -f "$work" 2>/dev/null
    else
        rm -f "$tmp" 2>/dev/null
        mv -f "$work" "$PENDING/$qfile" 2>/dev/null
    fi
    # Back off so an unreachable endpoint doesn't hot-loop the queue.
    sleep $(( attempts * 2 ))
done
