#!/bin/sh
set -e
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
PACKAGED="$ROOT/packaged"
OUT_NAME="asuswrt-merlin-stealthsurf.tar.gz"
OUT="$PACKAGED/$OUT_NAME"
STAGE="$ROOT/.pack-stage"

# Ensure dist is fresh
node "$ROOT/tools/build.mjs"

rm -rf "$STAGE"
mkdir -p "$STAGE/stealthsurf" "$PACKAGED"
cp "$DIST/stealthsurf" "$DIST/index.asp" "$DIST/app.js" "$STAGE/stealthsurf/"
chmod 0755 "$STAGE/stealthsurf/stealthsurf"
tar -czf "$OUT" -C "$STAGE" stealthsurf
# Keep a copy at repo root for local testing (gitignored via *.tar.gz — packaged/ is tracked)
cp -f "$OUT" "$ROOT/$OUT_NAME" 2>/dev/null || true
rm -rf "$STAGE"
echo "Packed $OUT"
ls -la "$OUT" "$PACKAGED"
