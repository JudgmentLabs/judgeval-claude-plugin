#!/usr/bin/env bats
#
# The repo is single-versioned: plugin.json, marketplace.json (top-level and
# every plugin entry), and pyproject.toml must all agree. release.yml gates a
# tag push on marketplace.json's version, so a drifted file ships a bad release.

setup() {
  PLUGIN_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  PLUGIN_JSON="$PLUGIN_ROOT/.claude-plugin/plugin.json"
  MARKETPLACE_JSON="$PLUGIN_ROOT/.claude-plugin/marketplace.json"
  PYPROJECT="$PLUGIN_ROOT/pyproject.toml"
}

@test "plugin.json version is a non-empty semver" {
  v="$(jq -r '.version' "$PLUGIN_JSON")"
  [ -n "$v" ] && [ "$v" != "null" ]
  [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "plugin.json and marketplace.json share the same top-level version" {
  a="$(jq -r '.version' "$PLUGIN_JSON")"
  b="$(jq -r '.version' "$MARKETPLACE_JSON")"
  [ "$a" = "$b" ]
}

@test "pyproject.toml version matches plugin.json version" {
  a="$(jq -r '.version' "$PLUGIN_JSON")"
  b="$(grep -E '^version = ' "$PYPROJECT" | head -1 | sed -E 's/version = "([^"]+)"/\1/')"
  [ "$a" = "$b" ]
}

@test "every marketplace plugin entry matches the marketplace version" {
  mkt="$(jq -r '.version' "$MARKETPLACE_JSON")"
  while read -r pv; do
    [ "$pv" = "$mkt" ]
  done < <(jq -r '.plugins[].version' "$MARKETPLACE_JSON")
}

@test "marketplace.json has the required top-level shape" {
  jq -e '.name and .owner.email and (.plugins | type == "array" and length > 0)' "$MARKETPLACE_JSON"
}

@test "every marketplace plugin entry has name, source and version" {
  jq -e '.plugins | all(.name and .source and .version)' "$MARKETPLACE_JSON"
}
