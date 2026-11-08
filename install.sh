#!/bin/sh
# StealthSurf 1.1.x installer for Asuswrt-Merlin (Entware required).
# Upgrades from 1.0.x and fresh installs use the same package layout:
#   stealthsurf/{stealthsurf,index.asp,app.js}
set -e

ADDON_REPO="${ADDON_REPO:-Homavi88/Stealthsurf-Asus}"
ASSET="asuswrt-merlin-stealthsurf.tar.gz"
TMP="/tmp/$ASSET"
JFFS_ADDONS="/jffs/addons"

echo "==> StealthSurf installer (1.1.x beta / XrayUI platform)"

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

echo "==> Done. Open VPN → StealthSurf in the router WebUI."
echo "    CLI: ssurf | ss | stealthsurf   (help: ssurf h)"
