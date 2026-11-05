#!/bin/sh
set -e
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
OUT="$ROOT/asuswrt-merlin-stealthsurf.tar.gz"
STAGE="$ROOT/.pack-stage"

rm -rf "$STAGE"
mkdir -p "$STAGE/stealthsurf"
cp "$DIST/stealthsurf" "$DIST/index.asp" "$DIST/app.js" "$STAGE/stealthsurf/"
chmod 0755 "$STAGE/stealthsurf/stealthsurf"
tar -czf "$OUT" -C "$STAGE" stealthsurf
rm -rf "$STAGE"
echo "Packed $OUT"
