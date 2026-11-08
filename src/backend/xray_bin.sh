#!/bin/sh
# Download / install Xray binary for router architecture + geodata helpers

ss_xray_resolve_bin() {
  if [ -x "$XRAY_BIN" ]; then
    return 0
  fi
  if [ -x /opt/sbin/xray ]; then
    XRAY_BIN="/opt/sbin/xray"
    return 0
  fi
  if [ -x /opt/bin/xray ]; then
    XRAY_BIN="/opt/bin/xray"
    return 0
  fi
  if command -v xray >/dev/null 2>&1; then
    XRAY_BIN=$(command -v xray)
    return 0
  fi
  return 1
}

ss_xray_status_json() {
  local installed=false ver="" path="" geoip=false geosite=false arch repo
  arch=$(ss_detect_arch 2>/dev/null || echo unknown)
  repo="${XRAY_REPO_URL:-https://github.com/XTLS/Xray-core/releases}"
  if ss_xray_resolve_bin; then
    installed=true
    path="$XRAY_BIN"
    ver=$("$XRAY_BIN" version 2>/dev/null | head -1 | tr -d '\r')
  fi
  [ -f "$GEOIP_DAT" ] && geoip=true
  [ -f "$GEOSITE_DAT" ] && geosite=true
  jq -nc \
    --argjson installed "$installed" \
    --arg path "$path" \
    --arg version "$ver" \
    --arg arch "$arch" \
    --arg repo "$repo" \
    --argjson geoip "$geoip" \
    --argjson geosite "$geosite" \
    --arg geoip_path "${GEOIP_DAT:-}" \
    --arg geosite_path "${GEOSITE_DAT:-}" \
    --arg geodata_base "${GEODATA_BASE:-}" \
    --arg geodata_preset "${SS_GEODATA_PRESET:-loyalsoldier}" \
    '{
      installed:$installed,
      path:(if $path=="" then null else $path end),
      version:(if $version=="" then null else $version end),
      arch:$arch,
      repo:$repo,
      geoip:$geoip,
      geosite:$geosite,
      geoip_path:$geoip_path,
      geosite_path:$geosite_path,
      geodata_base:$geodata_base,
      geodata_preset:$geodata_preset
    }' | tee "$SS_XRAY_INFO_FILE" 2>/dev/null
  ln -sf "$SS_XRAY_INFO_FILE" "$ADDON_WEB_DIR/xray_info.json" 2>/dev/null || true
}

ss_xray_list_versions() {
  # Cache recent Xray-core releases for WebUI (arch-filtered asset URLs)
  local arch json
  ss_ensure_dirs
  arch=$(ss_detect_arch)
  json=$(curl -fsSL -H "Accept: application/vnd.github+json" \
    -H "User-Agent: stealthsurf-merlin/$ADDON_VERSION" \
    "${XRAY_RELEASES_API:-https://api.github.com/repos/XTLS/Xray-core/releases?per_page=30}" 2>/dev/null) || json=""
  if [ -z "$json" ]; then
    jq -nc --arg arch "$arch" --arg err "github api unavailable" \
      '{arch:$arch, error:$err, releases:[], checked_at:(now|floor)}' |
      tee "$SS_XRAY_VERSIONS_FILE"
    ln -sf "$SS_XRAY_VERSIONS_FILE" "$ADDON_WEB_DIR/xray_versions.json" 2>/dev/null || true
    return 1
  fi
  printf '%s' "$json" | jq --arg arch "$arch" '
    {
      arch:$arch,
      error:null,
      checked_at:(now|floor),
      repo:"https://github.com/XTLS/Xray-core/releases",
      releases: [
        .[] | select(.draft|not) | {
          tag: .tag_name,
          name: (.name // .tag_name),
          prerelease: .prerelease,
          published_at: (.published_at // .created_at),
          html_url: .html_url,
          download_url: (
            (.assets // [])
            | map(select(.name == ("Xray-linux-" + $arch + ".zip")))
            | .[0].browser_download_url // null
          )
        }
        | select(.download_url != null)
      ][0:20]
    }
  ' | tee "$SS_XRAY_VERSIONS_FILE"
  ln -sf "$SS_XRAY_VERSIONS_FILE" "$ADDON_WEB_DIR/xray_versions.json" 2>/dev/null || true
}

ss_geodata_preset_base() {
  # Map preset id → download base (dir containing geoip.dat + geosite.dat)
  case "$1" in
  loyalsoldier | "" )
    echo "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download"
    ;;
  runetfreedom | runet)
    echo "https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download"
    ;;
  nidelon)
    echo "https://github.com/Nidelon/ru-block-v2ray-rules/releases/latest/download"
    ;;
  dustinwin)
    echo "https://github.com/DustinWin/ruleset_geodata/releases/latest/download"
    ;;
  chocolate4u | iran)
    echo "https://github.com/chocolate4u/Iran-v2ray-rules/releases/latest/download"
    ;;
  *)
    echo ""
    ;;
  esac
}

ss_geodata_apply_preset() {
  local preset="$1"
  local base
  [ -n "$preset" ] || return 0
  case "$preset" in
  custom) SS_GEODATA_PRESET="custom"; return 0 ;;
  esac
  base=$(ss_geodata_preset_base "$preset")
  [ -n "$base" ] || {
    ss_warn "Unknown geodata preset: $preset"
    return 1
  }
  SS_GEODATA_PRESET="$preset"
  SS_GEODATA_BASE="$base"
  GEODATA_BASE="$base"
}

ss_xray_install_from_opkg() {
  for cand in xray xray-core; do
    if opkg install "$cand" >/dev/null 2>&1; then
      if ss_xray_resolve_bin; then
        ss_ok "Installed xray via opkg ($cand)"
        return 0
      fi
    fi
  done
  return 1
}

ss_xray_download() {
  local arch zip url tmpdir asset ver want_tag="${1:-}"
  arch=$(ss_detect_arch)
  tmpdir="$ADDON_TMP_DIR/xray-dl.$$"
  mkdir -p "$tmpdir"

  ss_info "Resolving Xray release for arch=$arch${want_tag:+ tag=$want_tag}…"
  if [ -n "$want_tag" ]; then
    asset=$(curl -fsSL -H "Accept: application/vnd.github+json" \
      -H "User-Agent: stealthsurf-merlin/$ADDON_VERSION" \
      "https://api.github.com/repos/XTLS/Xray-core/releases/tags/${want_tag}" 2>/dev/null |
      jq -r --arg arch "$arch" '
        (.assets[] | select(.name | test("Xray-linux-" + $arch + "\\.zip$")) | .browser_download_url) // empty
      ' | head -1)
    ver="$want_tag"
  else
    asset=$(curl -fsSL -H "Accept: application/vnd.github+json" \
      -H "User-Agent: stealthsurf-merlin/$ADDON_VERSION" \
      "$XRAY_RELEASE_API" 2>/dev/null |
      jq -r --arg arch "$arch" '
        .tag_name as $v |
        (.assets[] | select(.name | test("Xray-linux-" + $arch + "\\.zip$")) | .browser_download_url) // empty
      ' | head -1)
  fi

  if [ -z "$asset" ]; then
    # Fallback known URL pattern — try latest tag via redirect
    ver=$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
      "https://github.com/XTLS/Xray-core/releases/latest" 2>/dev/null | sed 's|.*/||')
    [ -n "$ver" ] || ver="v25.10.15"
    [ -n "$want_tag" ] && ver="$want_tag"
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
  ss_xray_status_json >/dev/null 2>&1 || true
}

ss_ensure_xray() {
  if ss_xray_resolve_bin; then
    ss_xray_status_json >/dev/null 2>&1 || true
    return 0
  fi
  ss_info "Xray not found — trying opkg then GitHub download"
  ss_xray_install_from_opkg && {
    ss_xray_status_json >/dev/null 2>&1 || true
    return 0
  }
  ss_xray_download
}

ss_geodata_update() {
  ss_ensure_dirs
  mkdir -p "$(dirname "$GEOIP_DAT")"
  # Refresh base from conf/preset
  if [ -n "${SS_GEODATA_BASE:-}" ]; then
    GEODATA_BASE="$SS_GEODATA_BASE"
  fi
  ss_info "Updating geoip.dat / geosite.dat from $GEODATA_BASE …"
  if curl -fsSL -o "$GEOIP_DAT.tmp" "$GEODATA_BASE/geoip.dat" &&
    curl -fsSL -o "$GEOSITE_DAT.tmp" "$GEODATA_BASE/geosite.dat"; then
    mv -f "$GEOIP_DAT.tmp" "$GEOIP_DAT"
    mv -f "$GEOSITE_DAT.tmp" "$GEOSITE_DAT"
    ss_ok "Geodata updated"
    ss_xray_status_json >/dev/null 2>&1 || true
    return 0
  fi
  rm -f "$GEOIP_DAT.tmp" "$GEOSITE_DAT.tmp"
  ss_warn "Geodata update failed (will use bundled assets if present)"
  return 1
}
