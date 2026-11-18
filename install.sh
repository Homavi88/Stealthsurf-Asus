#!/bin/sh
# SurfGate (Homavi88/Stealthsurf-Asus) 1.4.11+ installer for Asuswrt-Merlin (Entware required).
#
# Package lives in /jffs/addons/ssurf — NEVER /jffs/addons/stealthsurf.
# The latter belongs to the official StealthSurf VPN daemon (stealthsurf-routerd
# on :8800). Older 1.2.0 installers wiped that tree; this one refuses to.
#
# Layout after extract:
#   ssurf/{stealthsurf,index.asp,app.js,panel/…}
# Runtime script: /jffs/scripts/ssurf (never /jffs/scripts/stealthsurf).
set -e

# Entware first — firmware BusyBox wget cannot fetch HTTPS (GitHub releases).
export PATH="/opt/bin:/opt/sbin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

ADDON_REPO="${ADDON_REPO:-Homavi88/Stealthsurf-Asus}"
ASSET="asuswrt-merlin-surfgate.tar.gz"
# Fallback for older release assets during transition
ASSET_LEGACY="asuswrt-merlin-stealthsurf.tar.gz"
TMP="/tmp/$ASSET"
JFFS_ADDONS="/jffs/addons"
# Own tree — must not collide with official StealthSurf VPN
OUR_DIR="$JFFS_ADDONS/ssurf"
OUR_SCRIPT="/jffs/scripts/ssurf"
# Official closed-source router package (cdn.stealthsurf.net merlin.sh)
OFFICIAL_DIR="$JFFS_ADDONS/stealthsurf"
OFFICIAL_DAEMON="$OFFICIAL_DIR/sbin/stealthsurf-routerd"

echo "==> SurfGate installer (1.4.11+ — panel :1131, path /jffs/addons/ssurf, script /jffs/scripts/ssurf)"

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
  echo "      /opt/bin/curl -fsSL https://cdn.stealthsurf.net/app/router/merlin.sh | sh"
fi

# Resolve an HTTPS-capable downloader. Merlin BusyBox wget only speaks http/ftp.
find_https_fetch() {
  if [ -x /opt/bin/curl ]; then
    echo "/opt/bin/curl"
    return 0
  fi
  if [ -x /usr/sbin/curl ]; then
    echo "/usr/sbin/curl"
    return 0
  fi
  if command -v curl >/dev/null 2>&1; then
    command -v curl
    return 0
  fi
  # Entware wget (wget-ssl), not BusyBox
  if [ -x /opt/bin/wget ]; then
    echo "/opt/bin/wget"
    return 0
  fi
  return 1
}

ensure_https_fetch() {
  if find_https_fetch >/dev/null 2>&1; then
    return 0
  fi
  echo "==> No HTTPS client found (BusyBox wget cannot download from GitHub)."
  echo "==> Installing Entware curl..."
  opkg update || true
  if ! opkg install curl; then
    echo "ERROR: could not install curl. Run manually:" >&2
    echo "  opkg update && opkg install curl" >&2
    echo "  then re-run this installer." >&2
    exit 1
  fi
  find_https_fetch >/dev/null 2>&1 || {
    echo "ERROR: curl installed but not found on PATH. Check /opt/bin/curl" >&2
    exit 1
  }
}

download_https() {
  # $1 = url, $2 = output path
  local url="$1" out="$2" bin
  bin=$(find_https_fetch) || return 1
  case "$bin" in
  *curl)
    "$bin" -fsSL --connect-timeout 30 --retry 3 -o "$out" "$url"
    ;;
  *wget)
    "$bin" -q --timeout=30 -O "$out" "$url"
    ;;
  *)
    return 1
    ;;
  esac
}

URL="https://github.com/${ADDON_REPO}/releases/latest/download/${ASSET}"
URL_LEGACY="https://github.com/${ADDON_REPO}/releases/latest/download/${ASSET_LEGACY}"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)
LOCAL_TGZ=""
if [ -n "$SCRIPT_DIR" ] && [ -s "$SCRIPT_DIR/packaged/$ASSET" ]; then
  LOCAL_TGZ="$SCRIPT_DIR/packaged/$ASSET"
elif [ -n "$SCRIPT_DIR" ] && [ -s "$SCRIPT_DIR/packaged/$ASSET_LEGACY" ]; then
  LOCAL_TGZ="$SCRIPT_DIR/packaged/$ASSET_LEGACY"
fi

if [ -n "$LOCAL_TGZ" ]; then
  echo "==> Using local package: $LOCAL_TGZ"
  cp -f "$LOCAL_TGZ" "$TMP"
else
  ensure_https_fetch
  echo "==> Downloading $URL"
  if ! download_https "$URL" "$TMP"; then
    echo "==> $ASSET not on latest release yet — trying $ASSET_LEGACY"
    if ! download_https "$URL_LEGACY" "$TMP"; then
      echo "ERROR: download failed." >&2
      echo "  Tried: $URL" >&2
      echo "  And:   $URL_LEGACY" >&2
      echo "  Fetcher: $(find_https_fetch 2>/dev/null || echo none)" >&2
      echo "  Manual: /opt/bin/curl -fsSL -o /tmp/$ASSET $URL && sh $0" >&2
      exit 1
    fi
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

mv -f "$OUR_DIR/stealthsurf" "$OUR_SCRIPT"
chmod 0755 "$OUR_SCRIPT"
# CLI aliases only — never /opt/bin/stealthsurf (official branding)
ln -sf "$OUR_SCRIPT" /opt/bin/surfgate 2>/dev/null || true
ln -sf "$OUR_SCRIPT" /opt/bin/ssurf 2>/dev/null || true
ln -sf "$OUR_SCRIPT" /opt/bin/ss 2>/dev/null || true
rm -f /opt/bin/stealthsurf 2>/dev/null || true
# Drop leftover Homavi88 script at legacy path if it is ours (never touch official)
if [ -f /jffs/scripts/stealthsurf ]; then
  if grep -q 'ADDON_TITLE="SurfGate"\|ADDON_PKG_NAME="ssurf"\|Homavi88' /jffs/scripts/stealthsurf 2>/dev/null; then
    rm -f /jffs/scripts/stealthsurf 2>/dev/null || true
  fi
fi

echo "==> Running SurfGate install"
sh "$OUR_SCRIPT" install

LAN=$(nvram get lan_ipaddr 2>/dev/null || echo "192.168.50.1")
echo "==> Done."
echo "    SurfGate panel:   http://${LAN}:1131/   (files in $OUR_DIR)"
echo "    Merlin WebUI:     VPN → SurfGate"
echo "    Official panel:   http://${LAN}:8800/   (untouched: $OFFICIAL_DIR)"
echo "    CLI: surfgate | ssurf | ss   (help: surfgate h)"
echo "    Restore official if broken:"
echo "      /opt/bin/curl -fsSL https://cdn.stealthsurf.net/app/router/merlin.sh | sh"
