# Shared setup for judgeval-claude-plugin bats tests.
#
# Sources the tracing hook library against an isolated HOME so tests never
# read or write the real ~/.claude state.

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOKS_DIR="$PLUGIN_ROOT/skills/trace-claude-code/hooks"

# Source common.sh with HOME pointed at the per-test tmp dir. common.sh derives
# LOG_FILE/STATE_FILE/LOCK_DIR/QUEUE_DIR from $HOME at source time, so HOME must
# be set *before* sourcing.
setup_common_env() {
  export HOME="$BATS_TEST_TMPDIR"
  mkdir -p "$HOME/.claude/state"
  export JUDGMENT_API_KEY="test-key"
  export JUDGMENT_ORG_ID="test-org"
  # shellcheck source=/dev/null
  source "$HOOKS_DIR/common.sh"
}
