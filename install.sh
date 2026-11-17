#!/bin/sh
# StealthSurf-Asus 1.2.1+ installer for Asuswrt-Merlin (Entware required).
#
# Package lives in /jffs/addons/ssurf — NEVER /jffs/addons/stealthsurf.
# The latter belongs to the official StealthSurf VPN daemon (stealthsurf-routerd
# on :8800). Older 1.2.0 installers wiped that tree; this one refuses to.
#
# Layout after extract:
#   ssurf/{stealthsurf,index.asp,app.js,panel/…}
set -e

ADDON_REPO="${ADDON_REPO:-Homavi88/Stealthsurf-Asus}"
ASSET="asuswrt-merlin-stealthsurf.tar.gz"
TMP="/tmp/$ASSET"
JFFS_ADDONS="/jffs/addons"
# Own tree — must not collide with official StealthSurf VPN
OUR_DIR="$JFFS_ADDONS/ssurf"
# Official closed-source router package (cdn.stealthsurf.net merlin.sh)
OFFICIAL_DIR="$JFFS_ADDONS/stealthsurf"
OFFICIAL_DAEMON="$OFFICIAL_DIR/sbin/stealthsurf-routerd"

echo "==> StealthSurf-Asus installer (1.2.1+ — panel :1131, path /jffs/addons/ssurf)"

if [ ! -d /jffs ]; then
  echo "ERROR: /jffs not found. Enable JFFS custom scripts in Administration → System." >&2
  exit 1
fi

if [ ! -x /opt/bin/opkg ]; then
  echo "ERROR: Entware (/opt/bin/opkg) is required." >&2
  echo "See: https://github.com/Entware/Entware/wiki/Install-on-ASUSWRT" >&2
  exit 1
fi

if [ -x "$OFFICIAL_DAEMON" ]; then
  echo "==> Official StealthSurf VPN detected at $OFFICIAL_DIR (will not touch it)."
elif [ -d "$OFFICIAL_DIR" ]; then
  echo "==> WARNING: $OFFICIAL_DIR exists without stealthsurf-routerd."
  echo "    If you previously installed our addon into that path, it may have"
  echo "    overwritten the official package. Reinstall official with:"
  echo "      curl -fsSL https://cdn.stealthsurf.net/app/router/merlin.sh | sh"
fi

URL="https://github.com/${ADDON_REPO}/releases/latest/download/${ASSET}"
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

# Migrate our files accidentally left under the official path (no routerd).
if [ ! -x "$OFFICIAL_DAEMON" ] && [ -f "$OFFICIAL_DIR/index.asp" -o -f "$OFFICIAL_DIR/app.js" -o -f "$OFFICIAL_DIR/index.panel.html" ]; then
  echo "==> Moving leftover Homavi88 files from $OFFICIAL_DIR → $OUR_DIR"
  mkdir -p "$OUR_DIR"
  for f in index.asp app.js index.panel.html panel stealthsurf; do
    if [ -e "$OFFICIAL_DIR/$f" ]; then
      rm -rf "$OUR_DIR/$f"
      mv -f "$OFFICIAL_DIR/$f" "$OUR_DIR/$f"
    fi
  done
  # Remove empty leftover dir only when it no longer looks like official
  if [ -d "$OFFICIAL_DIR" ] && [ ! -x "$OFFICIAL_DAEMON" ] && [ ! -d "$OFFICIAL_DIR/sbin" ]; then
    rmdir "$OFFICIAL_DIR" 2>/dev/null || true
  fi
fi

echo "==> Extracting to $OUR_DIR"
rm -rf "$OUR_DIR"
mkdir -p "$JFFS_ADDONS"
# Archive root is ssurf/…
tar -xzf "$TMP" -C "$JFFS_ADDONS"
rm -f "$TMP"

# Backward-compatible: old archives still packed as stealthsurf/
if [ ! -f "$OUR_DIR/stealthsurf" ] && [ -f "$JFFS_ADDONS/stealthsurf/stealthsurf" ]; then
  if [ -x "$OFFICIAL_DAEMON" ]; then
    echo "ERROR: got a legacy package root 'stealthsurf/' but official VPN is installed there." >&2
    echo "       Refusing to overwrite. Use a 1.2.1+ package (ssurf/)." >&2
    exit 1
  fi
  echo "==> Legacy package layout (stealthsurf/) — relocating to $OUR_DIR"
  rm -rf "$OUR_DIR"
  mv -f "$JFFS_ADDONS/stealthsurf" "$OUR_DIR"
fi

if [ ! -f "$OUR_DIR/stealthsurf" ]; then
  echo "ERROR: package missing ssurf/stealthsurf script" >&2
  exit 1
fi

mv -f "$OUR_DIR/stealthsurf" /jffs/scripts/stealthsurf
chmod 0755 /jffs/scripts/stealthsurf
ln -sf /jffs/scripts/stealthsurf /opt/bin/stealthsurf 2>/dev/null || true
ln -sf /jffs/scripts/stealthsurf /opt/bin/ssurf 2>/dev/null || true
ln -sf /jffs/scripts/stealthsurf /opt/bin/ss 2>/dev/null || true

echo "==> Running stealthsurf install"
sh /jffs/scripts/stealthsurf install

LAN=$(nvram get lan_ipaddr 2>/dev/null || echo "192.168.50.1")
echo "==> Done."
echo "    Our panel:        http://${LAN}:1131/   (files in $OUR_DIR)"
echo "    Merlin WebUI:     VPN → StealthSurf"
echo "    Official panel:   http://${LAN}:8800/   (untouched: $OFFICIAL_DIR)"
echo "    CLI: ssurf | ss | stealthsurf   (help: ssurf h)"
echo "    Restore official if broken:"
echo "      curl -fsSL https://cdn.stealthsurf.net/app/router/merlin.sh | sh"
