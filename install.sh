#!/bin/sh
# SurfGate (Homavi88/Stealthsurf-Asus) 1.4.22+ installer for Asuswrt-Merlin (Entware required).
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

# ── bootstrap TTY UI ──────────────────────────────────────────────────────
C0='\033[0m'
CCYAN='\033[0;36m'
CGREEN='\033[0;32m'
CRED='\033[0;31m'
CYELLOW='\033[0;33m'
CDIM='\033[0;90m'
CBLD='\033[1m'
if [ -t 1 ]; then UI_COLOR=1; else UI_COLOR=0; fi

ui_say() {
  if [ "$UI_COLOR" -eq 1 ]; then
    printf '%b›%b %s\n' "$CCYAN" "$C0" "$*"
  else
    echo "==> $*"
  fi
}
ui_ok() {
  if [ "$UI_COLOR" -eq 1 ]; then
    printf '  %b✓%b %s\n' "$CGREEN" "$C0" "$*"
  else
    echo "  [ok] $*"
  fi
}
ui_fail() {
  if [ "$UI_COLOR" -eq 1 ]; then
    printf '  %b✗%b %s\n' "$CRED" "$C0" "$*" >&2
  else
    echo "  [fail] $*" >&2
  fi
}
ui_warn() {
  if [ "$UI_COLOR" -eq 1 ]; then
    printf '  %b!%b %s\n' "$CYELLOW" "$C0" "$*"
  else
    echo "  [warn] $*"
  fi
}
ui_bar() {
  # $1 pct 0-100, $2 label
  pct=$1
  label=$2
  w=28
  [ "$pct" -gt 100 ] && pct=100
  filled=$((pct * w / 100))
  empty=$((w - filled))
  bar=''
  i=0
  while [ "$i" -lt "$filled" ]; do bar="${bar}█"; i=$((i + 1)); done
  i=0
  while [ "$i" -lt "$empty" ]; do bar="${bar}░"; i=$((i + 1)); done
  if [ "$UI_COLOR" -eq 1 ]; then
    printf '%b[%b%s%b]%b %3d%%  %s\n' "$CDIM" "$CCYAN" "$bar" "$CDIM" "$C0" "$pct" "$label"
  else
    echo "[$pct%] $label"
  fi
}
ui_banner() {
  if [ "$UI_COLOR" -eq 1 ]; then
    printf '\n%b┌─ %sSurfGate bootstrap%s ─────────────────────────┐%b\n' "$CCYAN" "$CBLD" "$CCYAN" "$C0"
    printf '%b│%b 1.4.22+ · panel :1131 · path /jffs/addons/ssurf%b│%b\n' "$CCYAN" "$CDIM" "$CCYAN" "$C0"
    printf '%b└──────────────────────────────────────────────────┘%b\n\n' "$CCYAN" "$C0"
  else
    echo "==> SurfGate installer (1.4.22+ — panel :1131, path /jffs/addons/ssurf, script /jffs/scripts/ssurf)"
  fi
}

ui_banner
ui_bar 5 "preflight"

if [ ! -d /jffs ]; then
  ui_fail "/jffs not found. Enable JFFS custom scripts in Administration → System."
  exit 1
fi

if [ ! -x /opt/bin/opkg ]; then
  ui_fail "Entware (/opt/bin/opkg) is required."
  echo "See: https://github.com/Entware/Entware/wiki/Install-on-ASUSWRT" >&2
  exit 1
fi
ui_ok "JFFS + Entware"

if [ -x "$OFFICIAL_DAEMON" ]; then
  ui_ok "Official StealthSurf VPN detected at $OFFICIAL_DIR (untouched)"
elif [ -d "$OFFICIAL_DIR" ]; then
  ui_warn "$OFFICIAL_DIR exists without stealthsurf-routerd"
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
  ui_say "No HTTPS client (BusyBox wget cannot download from GitHub) — installing curl"
  opkg update || true
  if ! opkg install curl; then
    ui_fail "could not install curl. Run: opkg update && opkg install curl"
    exit 1
  fi
  find_https_fetch >/dev/null 2>&1 || {
    ui_fail "curl installed but not found on PATH (/opt/bin/curl)"
    exit 1
  }
}

download_https() {
  # $1 = url, $2 = output path
  url="$1"
  out="$2"
  bin=$(find_https_fetch) || return 1
  case "$bin" in
  *curl)
    if [ "$UI_COLOR" -eq 1 ] && [ -t 2 ]; then
      "$bin" -fL --connect-timeout 30 --retry 3 --progress-bar -o "$out" "$url" 2>&1
    else
      "$bin" -fsSL --connect-timeout 30 --retry 3 -o "$out" "$url"
    fi
    ;;
  *wget)
    "$bin" -q --timeout=30 -O "$out" "$url"
    ;;
  *)
    return 1
    ;;
  esac
}

# GitHub mirrors for blocked regions (same set as addon github.sh)
download_https_mirrored() {
  url="$1"
  out="$2"
  if download_https "$url" "$out" && [ -s "$out" ]; then
    return 0
  fi
  for mirror in \
    'https://ghfast.top/' \
    'https://gh-proxy.com/' \
    'https://cdn.gh-proxy.org/' \
    'https://gitproxy.click/'; do
    ui_warn "retry via $mirror"
    if download_https "${mirror}${url}" "$out" && [ -s "$out" ]; then
      return 0
    fi
  done
  return 1
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

ui_bar 20 "fetch package"
if [ -n "$LOCAL_TGZ" ]; then
  ui_say "Using local package: $LOCAL_TGZ"
  cp -f "$LOCAL_TGZ" "$TMP"
  ui_ok "local $ASSET"
else
  ensure_https_fetch
  ui_ok "HTTPS client: $(find_https_fetch)"
  ui_say "Downloading $URL"
  if ! download_https_mirrored "$URL" "$TMP"; then
    ui_warn "$ASSET missing on latest — trying $ASSET_LEGACY"
    if ! download_https_mirrored "$URL_LEGACY" "$TMP"; then
      ui_fail "download failed"
      echo "  Tried: $URL" >&2
      echo "  And:   $URL_LEGACY" >&2
      echo "  Fetcher: $(find_https_fetch 2>/dev/null || echo none)" >&2
      echo "  Manual: /opt/bin/curl -fsSL -o /tmp/$ASSET $URL && sh $0" >&2
      exit 1
    fi
  fi
  ui_ok "downloaded $(wc -c <"$TMP" | tr -d ' ') bytes"
fi

# Migrate our files accidentally left under the official path (no routerd).
ui_bar 40 "prepare paths"
if [ ! -x "$OFFICIAL_DAEMON" ] && [ -f "$OFFICIAL_DIR/index.asp" -o -f "$OFFICIAL_DIR/app.js" -o -f "$OFFICIAL_DIR/index.panel.html" ]; then
  ui_say "Moving leftover Homavi88 files from $OFFICIAL_DIR → $OUR_DIR"
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

ui_bar 55 "extract → $OUR_DIR"
rm -rf "$OUR_DIR"
mkdir -p "$JFFS_ADDONS"
# Archive root is ssurf/…
tar -xzf "$TMP" -C "$JFFS_ADDONS"
rm -f "$TMP"
ui_ok "extracted"

# Backward-compatible: old archives still packed as stealthsurf/
if [ ! -f "$OUR_DIR/stealthsurf" ] && [ -f "$JFFS_ADDONS/stealthsurf/stealthsurf" ]; then
  if [ -x "$OFFICIAL_DAEMON" ]; then
    ui_fail "got a legacy package root 'stealthsurf/' but official VPN is installed there."
    echo "       Refusing to overwrite. Use a 1.2.1+ package (ssurf/)." >&2
    exit 1
  fi
  ui_warn "Legacy package layout (stealthsurf/) — relocating to $OUR_DIR"
  rm -rf "$OUR_DIR"
  mv -f "$JFFS_ADDONS/stealthsurf" "$OUR_DIR"
fi

if [ ! -f "$OUR_DIR/stealthsurf" ]; then
  ui_fail "package missing ssurf/stealthsurf script"
  exit 1
fi

ui_bar 70 "link CLI"
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
ui_ok "script $OUR_SCRIPT + surfgate/ssurf/ss"

ui_bar 80 "addon install (modules + geodata)"
ui_say "Running SurfGate install — colorful module/geodata progress follows"
sh "$OUR_SCRIPT" install

LAN=$(nvram get lan_ipaddr 2>/dev/null || echo "192.168.50.1")
ui_bar 100 "done"
if [ "$UI_COLOR" -eq 1 ]; then
  printf '\n%b╔════════════════════════════════════════════════╗%b\n' "$CGREEN" "$C0"
  printf '%b║%b  SurfGate ready                                %b║%b\n' "$CGREEN" "$C0" "$CGREEN" "$C0"
  printf '%b║%b  panel   http://%s:1131/               %b║%b\n' "$CGREEN" "$C0" "$LAN" "$CGREEN" "$C0"
  printf '%b║%b  WebUI   VPN → SurfGate                         %b║%b\n' "$CGREEN" "$C0" "$CGREEN" "$C0"
  printf '%b║%b  CLI     surfgate | ssurf | ss                  %b║%b\n' "$CGREEN" "$C0" "$CGREEN" "$C0"
  printf '%b╚════════════════════════════════════════════════╝%b\n' "$CGREEN" "$C0"
  printf '%b  official panel :8800 untouched (%s)%b\n\n' "$CDIM" "$OFFICIAL_DIR" "$C0"
else
  echo "==> Done."
  echo "    SurfGate panel:   http://${LAN}:1131/   (files in $OUR_DIR)"
  echo "    Merlin WebUI:     VPN → SurfGate"
  echo "    Official panel:   http://${LAN}:8800/   (untouched: $OFFICIAL_DIR)"
  echo "    CLI: surfgate | ssurf | ss   (help: surfgate h)"
fi
echo "    Restore official if broken:"
echo "      /opt/bin/curl -fsSL https://cdn.stealthsurf.net/app/router/merlin.sh | sh"
