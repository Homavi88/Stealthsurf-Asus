#!/bin/sh
# StealthSurf Asuswrt-Merlin — one-command installer
# Usage on router (Entware must already be installed via amtm):
#   curl -fsSL https://raw.githubusercontent.com/Homavi88/Stealthsurf-Asus/main/install.sh | sh
#   wget -qO- https://raw.githubusercontent.com/Homavi88/Stealthsurf-Asus/main/install.sh | sh

set -e

REPO_RAW="https://raw.githubusercontent.com/Homavi88/Stealthsurf-Asus/main"
REPO_TARBALL_RAW="${REPO_RAW}/packaged/asuswrt-merlin-stealthsurf.tar.gz"
REPO_TARBALL_RELEASE="https://github.com/Homavi88/Stealthsurf-Asus/releases/latest/download/asuswrt-merlin-stealthsurf.tar.gz"

ADDON_TAG="stealthsurf"
TMP_TGZ="/tmp/asuswrt-merlin-stealthsurf.tar.gz"
ADDON_DIR="/jffs/addons/${ADDON_TAG}"
SCRIPT_DST="/jffs/scripts/${ADDON_TAG}"

log() { printf '%s\n' "[stealthsurf-install] $*"; }
die() { printf '%s\n' "[stealthsurf-install] ERROR: $*" >&2; exit 1; }

require_rootish() {
  # Merlin installs usually run as admin over SSH
  touch /jffs/.stealthsurf_write_test 2>/dev/null || die "No write access to /jffs (enable JFFS custom scripts?)"
  rm -f /jffs/.stealthsurf_write_test
}

check_merlin_jffs() {
  if [ ! -d /jffs ]; then
    die "/jffs not found — Asuswrt-Merlin with JFFS required"
  fi
  # soft check: nvram may exist
  if command -v nvram >/dev/null 2>&1; then
    jffs_enable=$(nvram get jffs2_scripts 2>/dev/null || true)
    if [ "$jffs_enable" = "0" ]; then
      die "JFFS custom scripts are disabled. Enable: Administration → System → Enable JFFS custom scripts and configs = Yes, then reboot"
    fi
  fi
}

check_entware() {
  log "Checking Entware…"
  if [ ! -d /opt ]; then
    die "Entware not found (/opt missing). Install Entware first via amtm, then re-run this installer."
  fi
  if [ ! -x /opt/bin/opkg ] && [ ! -x /opt/sbin/opkg ]; then
    die "Entware opkg not found. Install Entware via amtm (Entware must be installed BEFORE this addon), then re-run."
  fi
  # Prefer PATH with Entware first
  export PATH="/opt/bin:/opt/sbin:/sbin:/bin:/usr/sbin:/usr/bin:$PATH"
  if ! command -v opkg >/dev/null 2>&1; then
    die "opkg is not in PATH after Entware check"
  fi
  log "Entware OK ($(command -v opkg))"
}

install_entware_deps() {
  log "Installing / updating Entware dependencies…"
  # Refresh package lists (best-effort)
  opkg update >/dev/null 2>&1 || log "opkg update failed (continuing with local package index)"

  # Package names differ slightly across Entware feeds; try primary then aliases
  # flock may be in flock or util-linux
  for spec in \
    "curl:curl" \
    "jq:jq" \
    "ca-certificates:ca-certificates" \
    "libopenssl:libopenssl openssl-util" \
    "coreutils-base64:coreutils-base64" \
    "flock:flock" \
    "iptables:iptables" \
    "ipset:ipset" \
    "unzip:unzip"
  do
    pkg=${spec%%:*}
    alts=${spec#*:}
    if opkg list-installed 2>/dev/null | grep -q "^${pkg} "; then
      log "  already installed: $pkg"
      continue
    fi
    installed=0
    for cand in $alts; do
      if opkg install "$cand" >/dev/null 2>&1; then
        log "  installed: $cand"
        installed=1
        break
      fi
    done
    if [ "$installed" -ne 1 ]; then
      log "  WARN: could not install '$pkg' (tried: $alts) — install manually later if needed"
    fi
  done

  # Xray: prefer Entware package, else download from GitHub Releases by arch
  if ! command -v xray >/dev/null 2>&1 && [ ! -x /opt/sbin/xray ] && [ ! -x /opt/bin/xray ]; then
    for cand in xray xray-core; do
      if opkg install "$cand" >/dev/null 2>&1; then
        log "  installed dataplane: $cand"
        break
      fi
    done
  else
    log "  xray already present"
  fi

  if ! command -v xray >/dev/null 2>&1 && [ ! -x /opt/sbin/xray ] && [ ! -x /opt/bin/xray ]; then
    log "  Xray not in opkg — will download during addon install (stealthsurf install-xray)"
  fi

  # unzip needed for Xray zip from GitHub
  if ! command -v unzip >/dev/null 2>&1; then
    opkg install unzip >/dev/null 2>&1 || log "  WARN: unzip missing — GitHub Xray download may fail"
  fi

  command -v curl >/dev/null 2>&1 || die "curl is required but not available after dependency install"
  command -v jq >/dev/null 2>&1 || die "jq is required but not available after dependency install"
}

download_package() {
  log "Downloading addon package…"
  rm -f "$TMP_TGZ"

  if command -v curl >/dev/null 2>&1; then
    if curl -fsSL -o "$TMP_TGZ" "$REPO_TARBALL_RELEASE" 2>/dev/null; then
      log "Downloaded from GitHub Releases"
      return 0
    fi
    if curl -fsSL -o "$TMP_TGZ" "$REPO_TARBALL_RAW" 2>/dev/null; then
      log "Downloaded from repository packaged/ (main)"
      return 0
    fi
  fi

  if command -v wget >/dev/null 2>&1; then
    if wget -q -O "$TMP_TGZ" "$REPO_TARBALL_RELEASE" 2>/dev/null; then
      log "Downloaded from GitHub Releases (wget)"
      return 0
    fi
    if wget -q -O "$TMP_TGZ" "$REPO_TARBALL_RAW" 2>/dev/null; then
      log "Downloaded from repository packaged/ (wget)"
      return 0
    fi
  fi

  die "Could not download package. Check network / GitHub access from the router."
}

extract_and_place() {
  [ -s "$TMP_TGZ" ] || die "Empty package archive"
  log "Installing files to $ADDON_DIR …"
  rm -rf "$ADDON_DIR"
  mkdir -p /jffs/addons /jffs/scripts
  tar -xzf "$TMP_TGZ" -C /jffs/addons
  [ -f "$ADDON_DIR/stealthsurf" ] || die "Archive layout invalid (missing $ADDON_DIR/stealthsurf)"
  [ -f "$ADDON_DIR/index.asp" ] || die "Archive layout invalid (missing index.asp)"
  [ -f "$ADDON_DIR/app.js" ] || die "Archive layout invalid (missing app.js)"

  mv -f "$ADDON_DIR/stealthsurf" "$SCRIPT_DST"
  chmod 0755 "$SCRIPT_DST"
  # keep UI assets in ADDON_DIR
  ln -sf "$SCRIPT_DST" "/opt/bin/${ADDON_TAG}" 2>/dev/null || true
}

run_addon_install() {
  log "Running ${ADDON_TAG} install…"
  sh "$SCRIPT_DST" install || die "Addon install step failed"
}

main() {
  log "StealthSurf Merlin installer"
  require_rootish
  check_merlin_jffs
  check_entware
  install_entware_deps
  download_package
  extract_and_place
  run_addon_install
  rm -f "$TMP_TGZ"
  log "Done."
  log "1) Log out and back into the router WebUI"
  log "2) Open VPN → StealthSurf"
  log "3) Or CLI: stealthsurf set-key 'stlth_...'"
}

main "$@"
