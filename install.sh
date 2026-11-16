#!/bin/sh
# StealthSurf 1.2.x installer for Asuswrt-Merlin (Entware required).
# Package layout:
#   stealthsurf/{stealthsurf,index.asp,app.js,panel/…}
# After install the standalone panel listens on LAN IP (or panel_ip) port 1131 —
# analogous to official StealthSurf on :8800, without sharing that proprietary daemon.
set -e

ADDON_REPO="${ADDON_REPO:-Homavi88/Stealthsurf-Asus}"
ASSET="asuswrt-merlin-stealthsurf.tar.gz"
TMP="/tmp/$ASSET"
JFFS_ADDONS="/jffs/addons"

echo "==> StealthSurf installer (1.2.x — Merlin tab + panel :1131)"

if [ ! -d /jffs ]; then
  echo "ERROR: /jffs not found. Enable JFFS custom scripts in Administration → System." >&2
  exit 1
fi

if [ ! -x /opt/bin/opkg ]; then
  echo "ERROR: Entware (/opt/bin/opkg) is required." >&2
  echo "See: https://github.com/Entware/Entware/wiki/Install-on-ASUSWRT" >&2
  exit 1
fi

URL="https://github.com/${ADDON_REPO}/releases/latest/download/${ASSET}"
# Prefer packaged/ from the same commit when running from a git checkout / CI artifact
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)
LOCAL_TGZ=""
if [ -n "$SCRIPT_DIR" ] && [ -s "$SCRIPT_DIR/packaged/$ASSET" ]; then
  LOCAL_TGZ="$SCRIPT_DIR/packaged/$ASSET"
fi

if [ -n "$LOCAL_TGZ" ]; then
  echo "==> Using local package: $LOCAL_TGZ"
  cp -f "$LOCAL_TGZ" "$TMP"
else
  echo "==> Downloading $URL"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$TMP" "$URL"
  else
    wget -q -O "$TMP" "$URL"
  fi
fi

echo "==> Extracting to $JFFS_ADDONS"
rm -rf "$JFFS_ADDONS/stealthsurf"
mkdir -p "$JFFS_ADDONS"
tar -xzf "$TMP" -C "$JFFS_ADDONS"
rm -f "$TMP"

if [ ! -f "$JFFS_ADDONS/stealthsurf/stealthsurf" ]; then
  echo "ERROR: package missing stealthsurf/stealthsurf binary" >&2
  exit 1
fi

mv -f "$JFFS_ADDONS/stealthsurf/stealthsurf" /jffs/scripts/stealthsurf
chmod 0755 /jffs/scripts/stealthsurf
ln -sf /jffs/scripts/stealthsurf /opt/bin/stealthsurf 2>/dev/null || true
ln -sf /jffs/scripts/stealthsurf /opt/bin/ssurf 2>/dev/null || true
ln -sf /jffs/scripts/stealthsurf /opt/bin/ss 2>/dev/null || true

echo "==> Running stealthsurf install"
sh /jffs/scripts/stealthsurf install

LAN=$(nvram get lan_ipaddr 2>/dev/null || echo "192.168.50.1")
echo "==> Done."
echo "    Standalone panel: http://${LAN}:1131/   (ssurf panel status)"
echo "    Merlin WebUI:     VPN → StealthSurf"
echo "    CLI: ssurf | ss | stealthsurf   (help: ssurf h)"
echo "    Optional dedicated IP: echo panel_ip=192.168.50.2 >> /opt/etc/stealthsurf.conf && ssurf panel restart"
