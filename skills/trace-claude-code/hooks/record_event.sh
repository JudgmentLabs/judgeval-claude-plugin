#!/bin/bash
###
# Record-only hook - captures a hook event's stdin payload for development.
#
# Modeled on the Braintrust plugin's record_event.sh: register this for any
# lifecycle event to learn exactly what data Claude Code provides, without
# affecting behavior. When JUDGEVAL_CC_RECORD_DIR is unset it is a
# near-instant no-op (stdin is not even read). Never fails the event.
#
# Usage (from settings hooks):
#   "command": "bash <hooks_dir>/record_event.sh SubagentStart"
###

# Intentionally no `set -e`: a record-only hook must never abort an event.

[ -z "${JUDGEVAL_CC_RECORD_DIR:-}" ] && exit 0

EVENT_NAME="${1:-unknown_event}"
mkdir -p "$JUDGEVAL_CC_RECORD_DIR" 2>/dev/null || exit 0

INPUT=$(cat 2>/dev/null)
{
    printf '{"event":"%s","ts":"%s","payload":' "$EVENT_NAME" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf '%s' "${INPUT:-null}"
    printf '}\n'
} >> "$JUDGEVAL_CC_RECORD_DIR/events.ndjson" 2>/dev/null

exit 0
