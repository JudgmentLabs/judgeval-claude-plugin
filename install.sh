#!/bin/bash
# Judgeval Claude Code Plugin - Quick Install
# Downloads plugin and runs setup in current directory

set -e

REPO="JudgmentLabs/judgeval-claude-plugin"
BRANCH="main"
TMP_DIR=$(mktemp -d)

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

echo "Downloading Judgeval Claude Code plugin..."
curl -sL "https://github.com/$REPO/archive/$BRANCH.tar.gz" | tar -xz -C "$TMP_DIR"

PLUGIN_DIR="$TMP_DIR/judgeval-claude-plugin-$BRANCH"
bash "$PLUGIN_DIR/skills/trace-claude-code/setup.sh"
