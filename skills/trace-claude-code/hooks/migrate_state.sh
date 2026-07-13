#!/bin/bash
###
# One-time state migration - strips the large, now-dead conversation fields
# that older plugin versions stored inline in judgeval_state.json.
#
# Spawned detached by ensure_migration() when the state file is large, so it
# never blocks a hook or risks a hook timeout. Runs at most once at a time
# (pid-file lock), operates on the file directly (no giant shell variable),
# and writes atomically. Preserves every small coordination field, so it is
# safe even with concurrent live sessions. Current-format state has none of
# these fields, so the strip is a no-op there.
###

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

MIG_LOCK="$(dirname "$STATE_FILE")/judgeval_migrate.pid"

# Singleton: if another migration is live, exit; replace a stale pid file.
if ! ( set -C; echo "$$" > "$MIG_LOCK" ) 2>/dev/null; then
    owner=$(cat "$MIG_LOCK" 2>/dev/null || true)
    if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
        exit 0
    fi
    rm -f "$MIG_LOCK" 2>/dev/null
    ( set -C; echo "$$" > "$MIG_LOCK" ) 2>/dev/null || exit 0
fi
trap 'rm -f "$MIG_LOCK" 2>/dev/null' EXIT

# Re-check size (another migration may have already shrunk it).
SIZE=$(wc -c < "$STATE_FILE" 2>/dev/null | tr -d ' ' || true)
case "$SIZE" in ''|*[!0-9]*) exit 0;; esac
[ "$SIZE" -lt "$MIGRATE_THRESHOLD_BYTES" ] && exit 0

_migrate_strip() {
    local tmp="${STATE_FILE}.migrate.$$"
    # Delete the unbounded legacy fields from every session/mapping entry.
    # Current code stores parent_blob_ref + external blobs instead, so these
    # keys only exist in pre-upgrade files and are never read anymore.
    if jq -c '.sessions |= map_values(
                del(.parent_task_input_json, .parent_task_output_json,
                    .task_notification_task_input_json,
                    .task_notification_task_output_json))' \
            "$STATE_FILE" > "$tmp" 2>/dev/null \
       && jq -e 'type == "object"' "$tmp" >/dev/null 2>&1; then
        mv -f "$tmp" "$STATE_FILE" 2>/dev/null
        return 0
    fi
    rm -f "$tmp" 2>/dev/null
    return 1
}

if with_lock _migrate_strip; then
    NEW_SIZE=$(wc -c < "$STATE_FILE" 2>/dev/null | tr -d ' ' || echo '?')
    log "INFO" "State migrated: stripped legacy inline conversation fields ($SIZE -> $NEW_SIZE bytes)"
else
    log "WARN" "State migration failed; will retry on next session start"
fi

exit 0
