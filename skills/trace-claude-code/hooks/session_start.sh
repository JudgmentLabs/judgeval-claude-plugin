#!/bin/bash
###
# SessionStart Hook - Records Claude session metadata.
#
# Traces are created per user turn in user_prompt_submit.sh so interactive
# sessions become a collection of turn traces sharing judgment.session_id.
###

set -e
trap 'exit 0' ERR
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

debug "SessionStart hook triggered"
tracing_enabled || { debug "Tracing disabled"; exit 0; }
check_requirements || exit 0

# Self-heal a pre-upgrade bloated state file (detached; no-op when healthy).
# Done first so it runs even if the rest of this hook is slow on a big file.
ensure_migration

INPUT=$(cat)
debug "SessionStart input: $(echo "$INPUT" | head -c 500)"

echo "$INPUT" | jq -e '.' >/dev/null 2>&1 || { debug "Invalid JSON"; exit 0; }

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
[ -z "$SESSION_ID" ] && SESSION_ID=$(generate_uuid)

WORKSPACE=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
TRANSCRIPT_PATH=$(find_transcript_path "$SESSION_ID" "$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)" || true)
# Cached lookup only; the background worker resolves the project by name.
PROJECT_ID=$(get_cached_project_id)

OFFSET=$(get_session_state "$SESSION_ID" "transcript_offset")
[ -z "$OFFSET" ] && OFFSET=$(count_file_lines "$TRANSCRIPT_PATH")

set_session_state_batch "$SESSION_ID" \
    "project_id" "$PROJECT_ID" \
    "workspace" "${WORKSPACE:-}" \
    "transcript_path" "${TRANSCRIPT_PATH:-}" \
    "transcript_offset" "${OFFSET:-0}"

# Sweep blob files left by crashed sessions (normal sessions prune at end).
# A blob is only live during its turn's subagent attach jobs; anything older
# than a day is certainly orphaned. Cheap: one find over a small dir.
[ -d "$BLOB_DIR" ] && find "$BLOB_DIR" -name '*.json' -type f -mtime +1 -delete 2>/dev/null || true

log "INFO" "Session observed: $SESSION_ID"
exit 0
