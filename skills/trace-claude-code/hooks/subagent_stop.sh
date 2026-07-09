#!/bin/bash
###
# SubagentStop Hook - Creates spans for subagent execution
#
# When a subagent (Task tool) completes, this hook:
# 1. Creates a container span for the subagent
# 2. Parses the subagent's transcript for LLM/tool spans
# 3. Links everything to the parent trace
###

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

debug "SubagentStop hook triggered"
tracing_enabled || { debug "Tracing disabled"; exit 0; }
check_requirements || exit 0

INPUT=$(cat)
debug "SubagentStop input: $(echo "$INPUT" | jq -c '.' 2>/dev/null | head -c 1000)"

echo "$INPUT" | jq -e '.' >/dev/null 2>&1 || { debug "Invalid JSON"; exit 0; }

# Extract subagent info from hook input
SUBAGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // .subagent_id // empty' 2>/dev/null)
SUBAGENT_TRANSCRIPT=$(echo "$INPUT" | jq -r '.agent_transcript_path // empty' 2>/dev/null)
TASK_DESCRIPTION=$(echo "$INPUT" | jq -r '.task // .description // empty' 2>/dev/null)
PARENT_SESSION_ID=$(echo "$INPUT" | jq -r '.parent_session_id // .session_id // empty' 2>/dev/null)
BACKGROUND_SUBAGENT_ID=$(echo "$INPUT" | jq -r '(.background_tasks // []) | map(select(.type == "subagent")) | .[0].id // empty' 2>/dev/null)
BACKGROUND_DESCRIPTION=$(echo "$INPUT" | jq -r '(.background_tasks // []) | map(select(.type == "subagent")) | .[0].description // empty' 2>/dev/null)

# Claude Code can emit a control SubagentStop while the real background task is
# still running. Its transcript path does not exist, and the real task id is in
# background_tasks, so skip it instead of creating an empty placeholder span.
if [ -n "$BACKGROUND_SUBAGENT_ID" ] && [ "$BACKGROUND_SUBAGENT_ID" != "$SUBAGENT_ID" ] &&
   { [ -z "$SUBAGENT_TRANSCRIPT" ] || [ ! -f "$SUBAGENT_TRANSCRIPT" ]; }; then
    debug "Skipping control SubagentStop for $SUBAGENT_ID; background task $BACKGROUND_SUBAGENT_ID is still running"
    exit 0
fi

# Get parent trace context. Prefer the durable Agent-tool mapping because async
# subagents can finish after the parent turn has already finalized.
MAPPED_PARENT_SESSION_ID=""
MAPPED_TRACE_ID=""
MAPPED_PROJECT_ID=""
MAPPED_ROOT_SPAN_ID=""
MAPPED_TASK_SPAN_ID=""
MAPPED_TURN_INDEX=""
MAPPED_DESCRIPTION=""
MAPPED_TRACED=""
MAPPED_TRACE_START=""
MAPPED_TASK_START=""
MAPPED_PARENT_TRACE_END=""
MAPPED_PARENT_TASK_INPUT_JSON=""
MAPPED_PARENT_TASK_OUTPUT_JSON=""
MAPPED_PARENT_LLM_CALLS=""
MAPPED_PARENT_TOOL_CALLS=""
MAPPED_PARENT_WORKSPACE=""
MAPPED_PARENT_WORKSPACE_NAME=""
MAPPED_PARENT_HOSTNAME=""
MAPPED_PARENT_USERNAME=""
MAPPED_PARENT_OS=""

if [ -n "$SUBAGENT_ID" ]; then
    IFS=$'\037' read -r MAPPED_PARENT_SESSION_ID MAPPED_TRACE_ID MAPPED_PROJECT_ID MAPPED_ROOT_SPAN_ID MAPPED_TASK_SPAN_ID MAPPED_TURN_INDEX MAPPED_DESCRIPTION MAPPED_TRACED MAPPED_TRACE_START MAPPED_TASK_START MAPPED_PARENT_TRACE_END MAPPED_PARENT_TASK_INPUT_JSON MAPPED_PARENT_TASK_OUTPUT_JSON MAPPED_PARENT_LLM_CALLS MAPPED_PARENT_TOOL_CALLS MAPPED_PARENT_WORKSPACE MAPPED_PARENT_WORKSPACE_NAME MAPPED_PARENT_HOSTNAME MAPPED_PARENT_USERNAME MAPPED_PARENT_OS \
        <<< "$(get_session_fields "subagent:$SUBAGENT_ID" parent_session_id trace_id project_id root_span_id task_span_id turn_index description transcript_traced trace_start task_start parent_trace_end parent_task_input_json parent_task_output_json parent_llm_calls parent_tool_calls parent_workspace parent_workspace_name parent_hostname parent_username parent_os)"
fi

if [ "$MAPPED_TRACED" = "true" ]; then
    debug "Subagent transcript already traced: $SUBAGENT_ID"
    exit 0
fi

TRACE_ID="$MAPPED_TRACE_ID"
PROJECT_ID="$MAPPED_PROJECT_ID"
ROOT_SPAN_ID="$MAPPED_ROOT_SPAN_ID"
PARENT_TASK_SPAN_ID="$MAPPED_TASK_SPAN_ID"
TURN_INDEX="$MAPPED_TURN_INDEX"

if [ -n "$MAPPED_PARENT_SESSION_ID" ]; then
    PARENT_SESSION_ID="$MAPPED_PARENT_SESSION_ID"
fi
if [ -z "$TASK_DESCRIPTION" ] && [ -n "$MAPPED_DESCRIPTION" ]; then
    TASK_DESCRIPTION="$MAPPED_DESCRIPTION"
fi
if [ -z "$TASK_DESCRIPTION" ] && [ -n "$BACKGROUND_DESCRIPTION" ]; then
    TASK_DESCRIPTION="$BACKGROUND_DESCRIPTION"
fi

if [ -z "$TRACE_ID" ]; then
    TRACE_ID=$(get_session_state "$PARENT_SESSION_ID" "active_trace_id")
    [ -z "$TRACE_ID" ] && TRACE_ID=$(get_state_value "current_trace_id")
    PARENT_TASK_SPAN_ID=$(get_session_state "$PARENT_SESSION_ID" "active_task_span_id")
    PROJECT_ID=$(get_session_state "$PARENT_SESSION_ID" "project_id")
    ROOT_SPAN_ID=$(get_session_state "$PARENT_SESSION_ID" "active_root_span_id")
    TURN_INDEX=$(get_session_state "$PARENT_SESSION_ID" "turn_count")
fi

[ -z "$TRACE_ID" ] && { debug "No current trace or mapped subagent trace"; exit 0; }

[ -z "$PROJECT_ID" ] && { debug "No project ID"; exit 0; }
[ -z "$ROOT_SPAN_ID" ] && { debug "No root span"; exit 0; }

# Use task span as parent if available, otherwise root
PARENT_SPAN_ID="${PARENT_TASK_SPAN_ID:-$ROOT_SPAN_ID}"

parent_update_id() {
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import time; print(int(time.time() * 1000))' 2>/dev/null && return
    fi
    echo 30
}

extend_parent_turn_spans() {
    [ -n "$MAPPED_PARENT_TASK_INPUT_JSON" ] && [ -n "$MAPPED_PARENT_TASK_OUTPUT_JSON" ] || { debug "No stored parent attrs for late subagent parent update"; return; }
    [ -n "$MAPPED_TRACE_START" ] && [ -n "$MAPPED_TASK_START" ] || { debug "No stored parent start time for late subagent parent update"; return; }
    echo "$MAPPED_PARENT_TASK_INPUT_JSON" | jq -e 'type == "string"' >/dev/null 2>&1 || { debug "Invalid stored parent input attrs"; return; }
    echo "$MAPPED_PARENT_TASK_OUTPUT_JSON" | jq -e 'type == "string"' >/dev/null 2>&1 || { debug "Invalid stored parent output attrs"; return; }

    local parent_end="$END_TIME"
    if [ -n "$MAPPED_PARENT_TRACE_END" ] && [ "$MAPPED_PARENT_TRACE_END" -gt "$parent_end" ] 2>/dev/null; then
        parent_end="$MAPPED_PARENT_TRACE_END"
    fi
    if [ -n "$MAPPED_PARENT_TRACE_END" ] && [ "$parent_end" -le "$MAPPED_PARENT_TRACE_END" ] 2>/dev/null; then
        return
    fi

    local update_id task_attrs task_span root_attrs root_span root_name
    update_id=$(parent_update_id)

    task_attrs=$(build_otlp_attributes "$(jq -n \
        --arg span_kind "task" \
        --argjson input "$MAPPED_PARENT_TASK_INPUT_JSON" \
        --argjson output "$MAPPED_PARENT_TASK_OUTPUT_JSON" \
        --argjson llm "${MAPPED_PARENT_LLM_CALLS:-0}" \
        --argjson tools "${MAPPED_PARENT_TOOL_CALLS:-0}" \
        --arg session_id "$PARENT_SESSION_ID" \
        --argjson turn_index "${TURN_INDEX:-1}" \
        '{
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
    task_span=$(build_otlp_span "$TRACE_ID" "$PARENT_TASK_SPAN_ID" "$ROOT_SPAN_ID" "Task" "task" "$MAPPED_TASK_START" "$parent_end" "$task_attrs" "$update_id")
    insert_span "$PROJECT_ID" "$task_span" >/dev/null || debug "Failed to extend parent task span"

    root_attrs=$(build_otlp_attributes "$(jq -n \
        --arg span_kind "task" \
        --argjson input "$MAPPED_PARENT_TASK_INPUT_JSON" \
        --argjson output "$MAPPED_PARENT_TASK_OUTPUT_JSON" \
        --arg session_id "$PARENT_SESSION_ID" \
        --arg workspace "${MAPPED_PARENT_WORKSPACE:-}" \
        --arg hostname "${MAPPED_PARENT_HOSTNAME:-$(get_hostname)}" \
        --arg username "${MAPPED_PARENT_USERNAME:-$(get_username)}" \
        --arg os "${MAPPED_PARENT_OS:-$(get_os)}" \
        --argjson turn_index "${TURN_INDEX:-1}" \
        '{
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
    root_name="Claude Code Turn: ${MAPPED_PARENT_WORKSPACE_NAME:-Claude Code}"
    root_span=$(build_otlp_span "$TRACE_ID" "$ROOT_SPAN_ID" "" "$root_name" "task" "$MAPPED_TRACE_START" "$parent_end" "$root_attrs" "$update_id")
    insert_span "$PROJECT_ID" "$root_span" >/dev/null || debug "Failed to extend parent root span"

    if [ -n "$SUBAGENT_ID" ] && [ -n "$MAPPED_TRACE_ID" ]; then
        set_session_state_batch "subagent:$SUBAGENT_ID" "parent_trace_end" "$parent_end"
    fi
}

# Generate subagent container span
SUBAGENT_SPAN_ID=$(generate_uuid | sed 's/-//g' | head -c 16)
START_TIME=$(get_time_nanos)

# If no transcript path provided, try to find it
if [ -z "$SUBAGENT_TRANSCRIPT" ] || [ ! -f "$SUBAGENT_TRANSCRIPT" ]; then
    if [ -n "$SUBAGENT_ID" ]; then
        for pattern in \
            "$HOME/.claude/projects/*/agent-${SUBAGENT_ID}.jsonl" \
            "$HOME/.claude/projects/*/${SUBAGENT_ID}.jsonl" \
            "$HOME/.claude/state/agent-${SUBAGENT_ID}.jsonl"; do
            FOUND=$(find $pattern -type f 2>/dev/null | head -1)
            if [ -n "$FOUND" ] && [ -f "$FOUND" ]; then
                SUBAGENT_TRANSCRIPT="$FOUND"
                debug "Found subagent transcript: $SUBAGENT_TRANSCRIPT"
                break
            fi
        done
    fi
fi

# Track subagent stats
LLM_CALLS=0
TOOL_CALLS=0
SUBAGENT_OUTPUT=""
SUBAGENT_FIRST_TIME=""
SUBAGENT_LAST_TIME=""

# Parse transcript for LLM and tool spans
if [ -n "$SUBAGENT_TRANSCRIPT" ] && [ -f "$SUBAGENT_TRANSCRIPT" ]; then
    debug "Parsing subagent transcript: $SUBAGENT_TRANSCRIPT"
    
    CURRENT_OUTPUT=""
    CURRENT_MODEL=""
CURRENT_PROMPT_TOKENS=0
CURRENT_COMPLETION_TOKENS=0
CURRENT_CACHE_CREATION=0
CURRENT_CACHE_READ=0
LLM_START_TIME=""
LLM_END_TIME=""
PENDING_TOOLS="{}"
CURRENT_TOOL_USES="[]"

subagent_llm_output_text() {
    local text="$1" tool_uses="$2"
    if [ -n "$text" ]; then
        printf '%s\n' "$text"
        return
    fi
    echo "$tool_uses" | jq -r 'if type == "array" and length > 0 then "Tool use: " + ([.[] | .name // "tool"] | join(", ")) else "" end' 2>/dev/null
}

    create_subagent_llm_span() {
        local output="$1" model="$2" prompt="$3" completion="$4"
        local cache_create="${5:-0}" cache_read="${6:-0}" start_time="$7" end_time="$8"
        [ -z "$output" ] && return
        
        local span_id provider input_json output_json attrs span usage_meta
        span_id=$(generate_uuid | sed 's/-//g' | head -c 16)
        provider=$(detect_provider "$model")
        
        input_json=$(jq -n --arg d "$TASK_DESCRIPTION" '[{role: "user", content: $d}]' | jq -c '.' | jq -Rs '.')
        output_json=$(jq -n --arg c "$output" '[{role: "assistant", content: $c}]' | jq -c '.' | jq -Rs '.')
        usage_meta=$(jq -n \
            --argjson inp "${prompt:-0}" \
            --argjson out "${completion:-0}" \
            --argjson cc "${cache_create:-0}" \
            --argjson cr "${cache_read:-0}" \
            '{input_tokens: $inp, output_tokens: $out, cache_creation_input_tokens: $cc, cache_read_input_tokens: $cr}' | jq -c '.')
        
        attrs=$(build_otlp_attributes "$(jq -n \
            --arg span_kind "llm" --argjson input "$input_json" --argjson output "$output_json" \
            --arg model "${model:-claude}" --arg provider "$provider" \
            --argjson prompt "$prompt" --argjson completion "$completion" \
            --argjson cache_create "${cache_create:-0}" --argjson cache_read "${cache_read:-0}" \
            --arg usage_meta "$usage_meta" \
            --arg session_id "$PARENT_SESSION_ID" \
            --argjson turn_index "${TURN_INDEX:-1}" \
            '{
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
              "subagent_id": "'"$SUBAGENT_ID"'",
              "judgment.session_id": $session_id,
              "session_id": $session_id,
              "turn_index": $turn_index
            }')")
        
        span=$(build_otlp_span "$TRACE_ID" "$span_id" "$SUBAGENT_SPAN_ID" "${model:-anthropic.messages.create}" "llm" "$start_time" "$end_time" "$attrs" 20)
        
        if insert_span "$PROJECT_ID" "$span" >/dev/null; then
            LLM_CALLS=$((LLM_CALLS + 1))
            debug "Subagent LLM span: $model"
        fi
    }

    create_subagent_tool_span() {
        local tool_name="$1" tool_input="$2" tool_output="$3" start_time="$4" end_time="$5"
        [ -z "$tool_name" ] && return
        
        local span_id input_json output_json attrs span
        span_id=$(generate_uuid | sed 's/-//g' | head -c 16)
        input_json=$(echo "$tool_input" | jq -c '.' 2>/dev/null | jq -Rs '.')
        output_json=$(echo "$tool_output" | jq -Rs '.')
        
        attrs=$(build_otlp_attributes "$(jq -n --arg span_kind "tool" --argjson input "$input_json" --argjson output "$output_json" --arg tool_name "$tool_name" --arg subagent_id "$SUBAGENT_ID" --arg session_id "$PARENT_SESSION_ID" --argjson turn_index "${TURN_INDEX:-1}" \
            '{"judgment.span_kind": $span_kind, "judgment.input": $input, "judgment.output": $output, "tool_name": $tool_name, "subagent_id": $subagent_id, "judgment.session_id": $session_id, "session_id": $session_id, "turn_index": $turn_index}')")
        
        span=$(build_otlp_span "$TRACE_ID" "$span_id" "$SUBAGENT_SPAN_ID" "$tool_name" "tool" "$start_time" "$end_time" "$attrs" 20)
        
        if insert_span "$PROJECT_ID" "$span" >/dev/null; then
            TOOL_CALLS=$((TOOL_CALLS + 1))
            debug "Subagent tool span: $tool_name"
        fi
    }

    # Parse the subagent transcript (same logic as session_end.sh)
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        
        MSG_TYPE=$(echo "$line" | jq -r '.type // empty' 2>/dev/null)
        TIMESTAMP=$(echo "$line" | jq -r '.timestamp // empty' 2>/dev/null)
        if [ -n "$TIMESTAMP" ]; then
            RECORD_TIME=$(iso_to_nanos "$TIMESTAMP")
            if [ -n "$RECORD_TIME" ]; then
                if [ -z "$SUBAGENT_FIRST_TIME" ] || [ "$RECORD_TIME" -lt "$SUBAGENT_FIRST_TIME" ] 2>/dev/null; then
                    SUBAGENT_FIRST_TIME="$RECORD_TIME"
                fi
                if [ -z "$SUBAGENT_LAST_TIME" ] || [ "$RECORD_TIME" -gt "$SUBAGENT_LAST_TIME" ] 2>/dev/null; then
                    SUBAGENT_LAST_TIME="$RECORD_TIME"
                fi
            fi
        fi
        
        if [ "$MSG_TYPE" = "user" ]; then
            CONTENT=$(echo "$line" | jq -c '.message.content // empty' 2>/dev/null)
            CONTENT_TYPE=""
            if echo "$CONTENT" | jq -e 'type == "array"' >/dev/null 2>&1; then
                CONTENT_TYPE=$(echo "$CONTENT" | jq -r '.[0].type // empty' 2>/dev/null)
            fi
            
            if [ "$CONTENT_TYPE" = "tool_result" ]; then
                # Flush pending LLM span
                LLM_OUTPUT=$(subagent_llm_output_text "$CURRENT_OUTPUT" "$CURRENT_TOOL_USES")
                if [ -n "$LLM_OUTPUT" ]; then
                    create_subagent_llm_span "$LLM_OUTPUT" "$CURRENT_MODEL" "$CURRENT_PROMPT_TOKENS" "$CURRENT_COMPLETION_TOKENS" "$CURRENT_CACHE_CREATION" "$CURRENT_CACHE_READ" "$LLM_START_TIME" "$LLM_END_TIME"
                    CURRENT_OUTPUT=""
                    CURRENT_TOOL_USES="[]"
                fi
                LLM_START_TIME=$(iso_to_nanos "$TIMESTAMP")
                
                # Process tool results
                TOOL_USE_RESULT=$(echo "$line" | jq -c '.toolUseResult // empty' 2>/dev/null)
                
                while IFS= read -r TOOL_RESULT; do
                    [ -z "$TOOL_RESULT" ] && continue
                    TOOL_USE_ID=$(echo "$TOOL_RESULT" | jq -r '.tool_use_id // empty')
                    
                    if [ -n "$TOOL_USE_RESULT" ] && [ "$TOOL_USE_RESULT" != "null" ]; then
                        TOOL_OUT=$(echo "$TOOL_USE_RESULT" | jq -r '.text // .content // "completed"' 2>/dev/null)
                    else
                        TOOL_OUT=$(echo "$TOOL_RESULT" | jq -r '.content // "result"')
                    fi
                    
                    if [ -n "$TOOL_USE_ID" ]; then
                        PENDING=$(echo "$PENDING_TOOLS" | jq -r ".\"$TOOL_USE_ID\" // empty")
                        if [ -n "$PENDING" ] && [ "$PENDING" != "null" ]; then
                            P_NAME=$(echo "$PENDING" | jq -r '.name')
                            P_INPUT=$(echo "$PENDING" | jq -r '.input')
                            P_START=$(echo "$PENDING" | jq -r '.start')
                            END_NANOS=$(iso_to_nanos "$TIMESTAMP")
                            create_subagent_tool_span "$P_NAME" "$P_INPUT" "$TOOL_OUT" "$P_START" "$END_NANOS"
                            PENDING_TOOLS=$(echo "$PENDING_TOOLS" | jq "del(.\"$TOOL_USE_ID\")")
                        fi
                    fi
                done < <(echo "$CONTENT" | jq -c '.[]' 2>/dev/null)
                
                CURRENT_MODEL=""; CURRENT_PROMPT_TOKENS=0; CURRENT_COMPLETION_TOKENS=0; CURRENT_CACHE_CREATION=0; CURRENT_CACHE_READ=0
            else
                # Regular user message - flush pending LLM span
                LLM_OUTPUT=$(subagent_llm_output_text "$CURRENT_OUTPUT" "$CURRENT_TOOL_USES")
                if [ -n "$LLM_OUTPUT" ]; then
                    create_subagent_llm_span "$LLM_OUTPUT" "$CURRENT_MODEL" "$CURRENT_PROMPT_TOKENS" "$CURRENT_COMPLETION_TOKENS" "$CURRENT_CACHE_CREATION" "$CURRENT_CACHE_READ" "$LLM_START_TIME" "$LLM_END_TIME"
                fi
                LLM_START_TIME=$(iso_to_nanos "$TIMESTAMP")
                CURRENT_OUTPUT=""; CURRENT_MODEL=""; CURRENT_PROMPT_TOKENS=0; CURRENT_COMPLETION_TOKENS=0; CURRENT_CACHE_CREATION=0; CURRENT_CACHE_READ=0; CURRENT_TOOL_USES="[]"
            fi
            
        elif [ "$MSG_TYPE" = "assistant" ]; then
            LLM_END_TIME=$(iso_to_nanos "$TIMESTAMP")
            
            # Track tool_use blocks
            if echo "$line" | jq -e '.message.content | type == "array"' >/dev/null 2>&1; then
                while IFS= read -r TOOL_USE; do
                    [ -z "$TOOL_USE" ] && continue
                    TOOL_ID=$(echo "$TOOL_USE" | jq -r '.id // empty')
                    TOOL_NAME=$(echo "$TOOL_USE" | jq -r '.name // empty')
                    TOOL_INPUT=$(echo "$TOOL_USE" | jq -c '.input // {}')
                    if [ -n "$TOOL_ID" ] && [ -n "$TOOL_NAME" ]; then
                        PENDING_TOOLS=$(echo "$PENDING_TOOLS" | jq --arg id "$TOOL_ID" --arg name "$TOOL_NAME" --arg input "$TOOL_INPUT" --arg start "$(iso_to_nanos "$TIMESTAMP")" \
                            '.[$id] = {name: $name, input: $input, start: $start}')
                        CURRENT_TOOL_USES=$(echo "$CURRENT_TOOL_USES" | jq --arg id "$TOOL_ID" --arg name "$TOOL_NAME" --argjson input "$TOOL_INPUT" \
                            '. += [{type: "tool_use", id: $id, name: $name, input: $input}]')
                    fi
                done < <(echo "$line" | jq -c '.message.content[] | select(.type == "tool_use")' 2>/dev/null)
            fi
            
            # Extract text
            TEXT=$(echo "$line" | jq -r '.message.content | if type == "array" then [.[] | select(.type == "text") | .text] | join("\n") else . end' 2>/dev/null)
            [ -n "$TEXT" ] && CURRENT_OUTPUT="${CURRENT_OUTPUT:+$CURRENT_OUTPUT$'\n'}$TEXT"
            
            # Extract model and usage
            MODEL=$(echo "$line" | jq -r '.message.model // .model // empty' 2>/dev/null)
            [ -n "$MODEL" ] && CURRENT_MODEL="$MODEL"
            
            # Claude Code repeats the same cumulative usage on every assistant content block
            # within a single API call, so use the latest values (replace) instead of accumulating
            USAGE=$(echo "$line" | jq -c '.message.usage // .usage // {}' 2>/dev/null)
            if [ -n "$USAGE" ] && [ "$USAGE" != "{}" ]; then
                INP=$(echo "$USAGE" | jq -r '.input_tokens // 0')
                [ "$INP" != "null" ] && [ "$INP" -gt 0 ] 2>/dev/null && CURRENT_PROMPT_TOKENS=$INP
                OUT=$(echo "$USAGE" | jq -r '.output_tokens // 0')
                [ "$OUT" != "null" ] && [ "$OUT" -gt 0 ] 2>/dev/null && CURRENT_COMPLETION_TOKENS=$OUT
                CC=$(echo "$USAGE" | jq -r '.cache_creation_input_tokens // 0')
                [ "$CC" != "null" ] && [ "$CC" -gt 0 ] 2>/dev/null && CURRENT_CACHE_CREATION=$CC
                CR=$(echo "$USAGE" | jq -r '.cache_read_input_tokens // 0')
                [ "$CR" != "null" ] && [ "$CR" -gt 0 ] 2>/dev/null && CURRENT_CACHE_READ=$CR
            fi
            
            # Save last output for subagent summary
            SUBAGENT_OUTPUT="$CURRENT_OUTPUT"
        fi
    done < "$SUBAGENT_TRANSCRIPT"
    
    # Flush final LLM span
    LLM_OUTPUT=$(subagent_llm_output_text "$CURRENT_OUTPUT" "$CURRENT_TOOL_USES")
    [ -n "$LLM_OUTPUT" ] && create_subagent_llm_span "$LLM_OUTPUT" "$CURRENT_MODEL" "$CURRENT_PROMPT_TOKENS" "$CURRENT_COMPLETION_TOKENS" "$CURRENT_CACHE_CREATION" "$CURRENT_CACHE_READ" "$LLM_START_TIME" "$LLM_END_TIME"
fi

# Create the subagent container span
END_TIME=$(get_time_nanos)
if [ -n "$SUBAGENT_FIRST_TIME" ]; then
    START_TIME="$SUBAGENT_FIRST_TIME"
fi
if [ -n "$SUBAGENT_LAST_TIME" ]; then
    END_TIME="$SUBAGENT_LAST_TIME"
fi
if [ "$START_TIME" -gt "$END_TIME" ] 2>/dev/null; then
    END_TIME="$START_TIME"
fi
TASK_INPUT_JSON=$(echo "${TASK_DESCRIPTION:-Subagent task}" | jq -Rs '.')
SUBAGENT_OUTPUT_JSON=$(echo "${SUBAGENT_OUTPUT:-Completed}" | jq -Rs '.')

SUBAGENT_ATTRS=$(build_otlp_attributes "$(jq -n \
    --arg span_kind "task" \
    --argjson input "$TASK_INPUT_JSON" \
    --argjson output "$SUBAGENT_OUTPUT_JSON" \
    --arg subagent_id "${SUBAGENT_ID:-unknown}" \
    --argjson llm_calls "$LLM_CALLS" \
    --argjson tool_calls "$TOOL_CALLS" \
    --arg session_id "$PARENT_SESSION_ID" \
    --argjson turn_index "${TURN_INDEX:-1}" \
    '{
        "judgment.span_kind": $span_kind,
        "judgment.input": $input,
        "judgment.output": $output,
        "subagent_id": $subagent_id,
        "llm_call_count": $llm_calls,
        "tool_count": $tool_calls,
        "judgment.session_id": $session_id,
        "session_id": $session_id,
        "turn_index": $turn_index
    }')")

SUBAGENT_SPAN=$(build_otlp_span "$TRACE_ID" "$SUBAGENT_SPAN_ID" "$PARENT_SPAN_ID" "Subagent: ${SUBAGENT_ID:-task}" "task" "$START_TIME" "$END_TIME" "$SUBAGENT_ATTRS" 0)

if insert_span "$PROJECT_ID" "$SUBAGENT_SPAN"; then
    extend_parent_turn_spans
    if [ -n "$SUBAGENT_ID" ] && [ -n "$MAPPED_TRACE_ID" ]; then
        set_session_state_batch "subagent:$SUBAGENT_ID" \
            "transcript_traced" "true" \
            "subagent_span_id" "$SUBAGENT_SPAN_ID"
    fi
    log "INFO" "Subagent traced: ${SUBAGENT_ID:-unknown} (llm=$LLM_CALLS, tools=$TOOL_CALLS)"
else
    log "ERROR" "Failed to create subagent span"
fi

exit 0
