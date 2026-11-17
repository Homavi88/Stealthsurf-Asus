#!/bin/sh
# Smoke-check panel helpers are present in the inlined stealthsurf script.
set -e
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
SCRIPT="$ROOT/packaged/asuswrt-merlin-stealthsurf.tar.gz"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if [ ! -s "$SCRIPT" ]; then
  echo "SKIP: packaged tarball missing (run pnpm pack first)" >&2
  exit 0
fi

tar -xzf "$SCRIPT" -C "$TMP"
BIN="$TMP/ssurf/stealthsurf"
test -f "$BIN"
grep -q 'PANEL_DEFAULT_PORT=1131' "$BIN"
grep -q 'panel_start()' "$BIN"
grep -q 'panel_bootstrap_json' "$BIN"
grep -q 'panel_api_handle' "$BIN"
grep -q 'panel_ensure_secondary_ip' "$BIN"
grep -q 'ADDON_PKG_NAME="ssurf"' "$BIN"
test -f "$TMP/ssurf/panel/index.html"
grep -q '__SS_PANEL__' "$TMP/ssurf/panel/index.html"
echo "panel.spec.sh OK"
