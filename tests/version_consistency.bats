#!/usr/bin/env bats
#
# The repo is single-versioned. The repo-root VERSION file is the single
# source of truth: pyproject.toml reads it dynamically (hatchling), and the
# JSON manifests are generated from it by scripts/sync_version.py. These tests
# assert nothing has drifted from VERSION, so a forgotten bump can't ship.

setup() {
  PLUGIN_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  VERSION_FILE="$PLUGIN_ROOT/VERSION"
  PLUGIN_JSON="$PLUGIN_ROOT/.claude-plugin/plugin.json"
  MARKETPLACE_JSON="$PLUGIN_ROOT/.claude-plugin/marketplace.json"
  PYPROJECT="$PLUGIN_ROOT/pyproject.toml"
  VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
}

@test "VERSION is a non-empty semver" {
  [ -n "$VERSION" ]
  [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "plugin.json version equals VERSION" {
  [ "$(jq -r '.version' "$PLUGIN_JSON")" = "$VERSION" ]
}

@test "marketplace.json top-level version equals VERSION" {
  [ "$(jq -r '.version' "$MARKETPLACE_JSON")" = "$VERSION" ]
}

@test "every marketplace plugin entry version equals VERSION" {
  while read -r pv; do
    [ "$pv" = "$VERSION" ]
  done < <(jq -r '.plugins[].version' "$MARKETPLACE_JSON")
}

@test "pyproject.toml has no hardcoded version (single-sourced from VERSION)" {
  # A static 'version = "x.y.z"' in [project] would reintroduce drift.
  run grep -nE '^[[:space:]]*version[[:space:]]*=' "$PYPROJECT"
  [ "$status" -ne 0 ]
}

@test "pyproject.toml declares a dynamic version sourced from the VERSION file" {
  grep -q 'dynamic = \["version"\]' "$PYPROJECT"
  grep -q '\[tool.hatch.version\]' "$PYPROJECT"
  grep -q 'path = "VERSION"' "$PYPROJECT"
}

@test "manifests are in sync with VERSION (sync_version.py --check)" {
  run python3 "$PLUGIN_ROOT/scripts/sync_version.py" --check
  [ "$status" -eq 0 ]
}

# --- shape checks (independent of the version value) -------------------------

@test "marketplace.json has the required top-level shape" {
  jq -e '.name and .owner.email and (.plugins | type == "array" and length > 0)' "$MARKETPLACE_JSON"
}

@test "every marketplace plugin entry has name, source and version" {
  jq -e '.plugins | all(.name and .source and .version)' "$MARKETPLACE_JSON"
}
