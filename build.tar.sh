#!/bin/bash

XRAYUI_VERSION=${1:-"1.2.1"}

NODE_ENV=production npx vite build

echo "Updating XRAYUI_VERSION to $XRAYUI_VERSION in /dist/stealthsurf"
sed -i "s/^XRAYUI_VERSION=.*/XRAYUI_VERSION=\"$XRAYUI_VERSION\"/" dist/stealthsurf

# Root dir in the archive is ssurf/ so we never collide with official
# /jffs/addons/stealthsurf (stealthsurf-routerd on :8800).
tar --transform 's|^|ssurf/|' -czf asuswrt-merlin-stealthsurf.tar.gz -C dist .
