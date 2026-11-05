#!/bin/sh
# Backup / restore addon settings + self-update from GitHub Releases

ss_backup() {
  local stamp name out
  ss_ensure_dirs
  stamp=$(date +%Y%m%d-%H%M%S)
  name="stealthsurf-backup-${stamp}.tar.gz"
  out="$ADDON_BACKUP_DIR/$name"
  tar -czf "$out" \
    -C / \
    "${SS_CONF_FILE#/}" \
    "${SS_POLICIES_FILE#/}" \
    "${SS_ROUTING_FILE#/}" \
    "${SS_OUTBOUNDS_FILE#/}" \
    "${SS_CACHE_CONFIGS#/}" \
    "${SS_CACHE_KEYS#/}" \
    "${SS_CACHE_SUBSCRIPTIONS#/}" \
    2>/dev/null || true
  # Also copy key JSON from share dir explicitly
  tar -czf "$out" \
    "$SS_CONF_FILE" \
    "$SS_POLICIES_FILE" \
    "$SS_ROUTING_FILE" \
    "$SS_OUTBOUNDS_FILE" \
    "$SS_CACHE_KEYS" \
    "$ADDON_SHARE_DIR/configs.json" \
    "$ADDON_SHARE_DIR/subscriptions.json" \
    2>/dev/null
  ss_ok "Backup written to $out"
  printf '%s\n' "$out"
}

ss_restore() {
  local archive="$1"
  [ -f "$archive" ] || {
    ss_error "usage: restore <backup.tar.gz>"
    return 1
  }
  ss_stop 2>/dev/null || true
  tar -xzf "$archive" -C / 2>/dev/null || tar -xzf "$archive" -C "$ADDON_SHARE_DIR"
  # Reload conf
  if [ -f "$SS_CONF_FILE" ]; then
    # shellcheck disable=SC1090
    . "$SS_CONF_FILE"
  fi
  ss_ok "Restored from $archive — run start if needed"
}

ss_update_self() {
  local tmp="/tmp/asuswrt-merlin-stealthsurf.tar.gz"
  ss_info "Downloading latest release…"
  if ! curl -fsSL -o "$tmp" "$ADDON_RELEASE_TGZ"; then
    ss_error "Could not download release tarball"
    return 1
  fi
  rm -rf "$ADDON_JFFS_ADN_DIR"
  mkdir -p /jffs/addons /jffs/scripts
  tar -xzf "$tmp" -C /jffs/addons
  [ -f "$ADDON_JFFS_ADN_DIR/stealthsurf" ] || {
    ss_error "Invalid release archive layout"
    return 1
  }
  mv -f "$ADDON_JFFS_ADN_DIR/stealthsurf" "$ADDON_SCRIPT"
  chmod 0755 "$ADDON_SCRIPT"
  ln -sf "$ADDON_SCRIPT" "/opt/bin/$ADDON_TAG" 2>/dev/null || true
  sh "$ADDON_SCRIPT" install || true
  rm -f "$tmp"
  ss_ok "Updated addon from GitHub Releases — re-login to WebUI"
}

ss_install_cron() {
  # Auto-sync + watchdog via cru (Merlin) or crontab
  local sync_line watch_line
  sync_line="*/30 * * * * /jffs/scripts/$ADDON_TAG autosync >/dev/null 2>&1"
  watch_line="*/5 * * * * /jffs/scripts/$ADDON_TAG watchdog >/dev/null 2>&1"

  if command -v cru >/dev/null 2>&1; then
    cru d stealthsurf_sync 2>/dev/null || true
    cru d stealthsurf_watch 2>/dev/null || true
    cru a stealthsurf_sync "*/30 * * * * /jffs/scripts/$ADDON_TAG autosync"
    cru a stealthsurf_watch "*/5 * * * * /jffs/scripts/$ADDON_TAG watchdog"
    ss_ok "Cron jobs installed via cru"
    return 0
  fi

  # Fallback: append to /var/spool/cron/crontabs/admin if present
  local cronf="/var/spool/cron/crontabs/admin"
  if [ -d "$(dirname "$cronf")" ]; then
    touch "$cronf"
    grep -q "$ADDON_TAG autosync" "$cronf" 2>/dev/null || echo "$sync_line" >>"$cronf"
    grep -q "$ADDON_TAG watchdog" "$cronf" 2>/dev/null || echo "$watch_line" >>"$cronf"
    ss_ok "Cron lines appended to $cronf"
  else
    ss_warn "No cru/crontab — schedule autosync manually"
  fi
}

ss_remove_cron() {
  if command -v cru >/dev/null 2>&1; then
    cru d stealthsurf_sync 2>/dev/null || true
    cru d stealthsurf_watch 2>/dev/null || true
  fi
}
