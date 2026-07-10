#!/usr/bin/env python3
"""Single-source version management for judgeval-claude-plugin.

The repo-root ``VERSION`` file is the single source of truth.

- ``pyproject.toml`` reads it dynamically at build time (hatchling), so it is
  never written here.
- ``.claude-plugin/plugin.json`` and ``.claude-plugin/marketplace.json`` are
  static manifests that Claude Code reads literally, so their ``version``
  fields are generated from ``VERSION`` by this script.

Usage:
  scripts/sync_version.py            Write VERSION into the JSON manifests.
  scripts/sync_version.py --check    Exit non-zero if any manifest has drifted.
  scripts/sync_version.py 1.2.3      Set VERSION to 1.2.3, then sync manifests.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VERSION_FILE = ROOT / "VERSION"
PLUGIN_JSON = ROOT / ".claude-plugin" / "plugin.json"
MARKETPLACE_JSON = ROOT / ".claude-plugin" / "marketplace.json"

SEMVER = re.compile(r"^\d+\.\d+\.\d+$")


def _fail(msg: str) -> "None":
    print(msg, file=sys.stderr)
    raise SystemExit(1)


def read_version() -> str:
    if not VERSION_FILE.exists():
        _fail(f"Missing {VERSION_FILE.relative_to(ROOT)}")
    version = VERSION_FILE.read_text(encoding="utf-8").strip()
    if not SEMVER.match(version):
        _fail(f"VERSION must be MAJOR.MINOR.PATCH, got {version!r}")
    return version


def _render(path: Path, version: str) -> str:
    """Return the canonical text for a manifest with ``version`` applied."""
    data = json.loads(path.read_text(encoding="utf-8"))
    data["version"] = version
    for plugin in data.get("plugins", []):
        plugin["version"] = version
    return json.dumps(data, indent=2) + "\n"


def main(argv: list[str]) -> int:
    check = "--check" in argv
    positional = [a for a in argv if not a.startswith("-")]

    if positional:
        new_version = positional[0]
        if not SEMVER.match(new_version):
            _fail(f"Target version must be MAJOR.MINOR.PATCH, got {new_version!r}")
        if not check:
            VERSION_FILE.write_text(new_version + "\n", encoding="utf-8")

    version = read_version()
    drift: list[Path] = []
    for path in (PLUGIN_JSON, MARKETPLACE_JSON):
        desired = _render(path, version)
        if path.read_text(encoding="utf-8") != desired:
            drift.append(path)
            if not check:
                path.write_text(desired, encoding="utf-8")

    rel = lambda p: str(p.relative_to(ROOT))
    if check:
        if drift:
            print(
                "Version drift from VERSION (%s) in: %s\n"
                "Run scripts/sync_version.py to fix."
                % (version, ", ".join(rel(p) for p in drift)),
                file=sys.stderr,
            )
            return 1
        print(f"All manifests match VERSION ({version}).")
        return 0

    if drift:
        print(f"Synced to {version}: " + ", ".join(rel(p) for p in drift))
    else:
        print(f"Already in sync at {version}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
