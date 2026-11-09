#!/bin/bash

XRAYUI_VERSION=${1:-"1.1.8"}

NODE_ENV=production npx vite build

echo "Updating XRAYUI_VERSION to $XRAYUI_VERSION in /dist/stealthsurf"
sed -i "s/^XRAYUI_VERSION=.*/XRAYUI_VERSION=\"$XRAYUI_VERSION\"/" dist/stealthsurf

tar --transform 's|^|stealthsurf/|' -czf asuswrt-merlin-stealthsurf.tar.gz -C dist .
