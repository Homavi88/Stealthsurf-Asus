#!/bin/sh
# Download / install Xray binary for router architecture

ss_xray_install_from_opkg() {
  for cand in xray xray-core; do
    if opkg install "$cand" >/dev/null 2>&1; then
      if [ -x /opt/sbin/xray ] || [ -x /opt/bin/xray ] || command -v xray >/dev/null 2>&1; then
        ss_ok "Installed xray via opkg ($cand)"
        return 0
      fi
    fi
  done
  return 1
}

ss_xray_download() {
  local arch zip url tmpdir asset ver
  arch=$(ss_detect_arch)
  tmpdir="$ADDON_TMP_DIR/xray-dl.$$"
  mkdir -p "$tmpdir"

  ss_info "Resolving Xray release for arch=$arch…"
  # Query GitHub API for asset matching Xray-linux-<arch>.zip
  asset=$(curl -fsSL -H "Accept: application/vnd.github+json" \
    -H "User-Agent: stealthsurf-merlin/$ADDON_VERSION" \
    "$XRAY_RELEASE_API" 2>/dev/null |
    jq -r --arg arch "$arch" '
      .tag_name as $v |
      (.assets[] | select(.name | test("Xray-linux-" + $arch + "\\.zip$")) | .browser_download_url) // empty
    ' | head -1)

  if [ -z "$asset" ]; then
    # Fallback known URL pattern — try latest tag via redirect
    ver=$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
      "https://github.com/XTLS/Xray-core/releases/latest" 2>/dev/null | sed 's|.*/||')
    [ -n "$ver" ] || ver="v25.10.15"
    asset="https://github.com/XTLS/Xray-core/releases/download/${ver}/Xray-linux-${arch}.zip"
  fi

  ss_info "Downloading $asset"
  if ! curl -fsSL -o "$tmpdir/xray.zip" "$asset"; then
    ss_error "Failed to download Xray binary"
    rm -rf "$tmpdir"
    return 1
  fi

  if command -v unzip >/dev/null 2>&1; then
    unzip -o "$tmpdir/xray.zip" -d "$tmpdir" >/dev/null || {
      ss_error "unzip failed"
      rm -rf "$tmpdir"
      return 1
    }
  else
    # busybox unzip
    unzip -o "$tmpdir/xray.zip" -d "$tmpdir" >/dev/null 2>&1 || {
      ss_error "No unzip available to extract Xray"
      rm -rf "$tmpdir"
      return 1
    }
  fi

  if [ ! -f "$tmpdir/xray" ]; then
    ss_error "xray binary missing in archive"
    rm -rf "$tmpdir"
    return 1
  fi

  mkdir -p /opt/sbin
  mv -f "$tmpdir/xray" /opt/sbin/xray
  chmod 0755 /opt/sbin/xray
  XRAY_BIN="/opt/sbin/xray"

  # Optional geo assets from same zip
  [ -f "$tmpdir/geoip.dat" ] && mv -f "$tmpdir/geoip.dat" "$GEOIP_DAT"
  [ -f "$tmpdir/geosite.dat" ] && mv -f "$tmpdir/geosite.dat" "$GEOSITE_DAT"

  rm -rf "$tmpdir"
  ss_ok "Xray installed to $XRAY_BIN ($($XRAY_BIN version 2>/dev/null | head -1))"
}

ss_ensure_xray() {
  if [ -x "$XRAY_BIN" ] || command -v xray >/dev/null 2>&1; then
    [ -x "$XRAY_BIN" ] || XRAY_BIN=$(command -v xray)
    return 0
  fi
  ss_info "Xray not found — trying opkg then GitHub download"
  ss_xray_install_from_opkg && return 0
  ss_xray_download
}

ss_geodata_update() {
  ss_ensure_dirs
  mkdir -p "$(dirname "$GEOIP_DAT")"
  ss_info "Updating geoip.dat / geosite.dat…"
  if curl -fsSL -o "$GEOIP_DAT.tmp" "$GEODATA_BASE/geoip.dat" &&
    curl -fsSL -o "$GEOSITE_DAT.tmp" "$GEODATA_BASE/geosite.dat"; then
    mv -f "$GEOIP_DAT.tmp" "$GEOIP_DAT"
    mv -f "$GEOSITE_DAT.tmp" "$GEOSITE_DAT"
    ss_ok "Geodata updated"
    return 0
  fi
  rm -f "$GEOIP_DAT.tmp" "$GEOSITE_DAT.tmp"
  ss_warn "Geodata update failed (will use bundled assets if present)"
  return 1
}
