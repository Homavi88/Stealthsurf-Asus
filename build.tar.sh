#!/bin/bash
set -euo pipefail

XRAYUI_VERSION=${1:-"1.4.45"}
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$ROOT"

NODE_ENV=production npx vite build

echo "Updating XRAYUI_VERSION to $XRAYUI_VERSION in /dist/stealthsurf"
sed -i "s/^XRAYUI_VERSION=.*/XRAYUI_VERSION=\"$XRAYUI_VERSION\"/" dist/stealthsurf

# Cache-bust Merlin ASP app.js URL so Safari does not keep a stale SPA after upgrade.
if [ -f dist/index.asp ]; then
  sed -i "s/__SS_UI_VERSION__/${XRAYUI_VERSION}/g" dist/index.asp
fi
if [ -f dist/app.html ]; then
  sed -i "s/__SS_UI_VERSION__/${XRAYUI_VERSION}/g" dist/app.html
fi
# Standalone panel HTML (also rewritten at runtime via bootstrap ?v=).
if [ -f dist/panel/index.html ]; then
  sed -i "s/__SS_UI_VERSION__/${XRAYUI_VERSION}/g" dist/panel/index.html
fi
if [ -f dist/index.panel.html ]; then
  sed -i "s/__SS_UI_VERSION__/${XRAYUI_VERSION}/g" dist/index.panel.html
fi

echo "Building bundled panel-httpd (static, no opkg needed on router)..."
mkdir -p dist/bin
(
  cd tools/panel-httpd
  CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -ldflags='-s -w' -o "$ROOT/dist/bin/panel-httpd.aarch64" .
  CGO_ENABLED=0 GOOS=linux GOARCH=arm GOARM=7 go build -trimpath -ldflags='-s -w' -o "$ROOT/dist/bin/panel-httpd.armv7" .
)
chmod 0755 dist/bin/panel-httpd.aarch64 dist/bin/panel-httpd.armv7
ls -la dist/bin/

# Root dir in the archive is ssurf/ so we never collide with official
# /jffs/addons/stealthsurf (stealthsurf-routerd on :8800).
tar --transform 's|^|ssurf/|' -czf asuswrt-merlin-surfgate.tar.gz -C dist .
echo "Wrote asuswrt-merlin-surfgate.tar.gz"
