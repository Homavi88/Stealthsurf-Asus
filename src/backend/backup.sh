#!/bin/sh
# Backup / restore addon configurations + self-update from GitHub Releases

SS_BACKUP_KEEP="${SS_BACKUP_KEEP:-10}"
SS_BACKUP_INDEX="$ADDON_BACKUP_DIR/index.json"
SS_AUTO_BACKUP="${SS_AUTO_BACKUP:-1}"

ss_backup_manifest() {
  # Build JSON manifest describing what is in the backup
  local stamp="$1"
  local note="$2"
  jq -nc \
    --arg version "$ADDON_VERSION" \
    --arg stamp "$stamp" \
    --arg note "${note:-}" \
    --arg mode "${SS_MODE}" \
    --arg dns "${SS_DNS_MODE}" \
    --arg active "${SS_ACTIVE_CONFIG_ID}" \
    --arg default "${SS_DEFAULT_OUTBOUND}" \
    --arg enabled "${SS_ENABLED_OUTBOUNDS}" \
    --argjson ts "$(date +%s)" \
    --argjson configs "$(jq 'length' "$SS_CACHE_CONFIGS" 2>/dev/null || echo 0)" \
    --argjson routing_rules "$(jq '(.rules // [])|length' "$SS_ROUTING_FILE" 2>/dev/null || echo 0)" \
    --argjson policies "$(jq '(.rules // [])|length' "$SS_POLICIES_FILE" 2>/dev/null || echo 0)" \
    '{
      version:$version, stamp:$stamp, note:$note, created_at:$ts,
      mode:$mode, dns_mode:$dns,
      active_config_id: (if $active=="" then null else ($active|tonumber?) // $active end),
      default_outbound: (if $default=="" then null else $default end),
      enabled_outbounds: (if $enabled=="" then [] else ($enabled|split(" ")|map(tonumber? // .)) end),
      counts: {configs:$configs, routing_rules:$routing_rules, policy_rules:$policies}
    }'
}

ss_backup_enrich_policies() {
  # Write policies copy with resolved device IPs for restore/audit
  local out="$1" rules_tmp mac ip name rule
  [ -f "$SS_POLICIES_FILE" ] || {
    echo '{"catchall":true,"rules":[]}' >"$out"
    return 0
  }
  rules_tmp="$ADDON_TMP_DIR/pol-enriched.$$"
  echo '[]' >"$rules_tmp"
  local i n
  n=$(jq '(.rules // [])|length' "$SS_POLICIES_FILE" 2>/dev/null || echo 0)
  i=0
  while [ "$i" -lt "$n" ]; do
    rule=$(jq -c --argjson i "$i" '.rules[$i]' "$SS_POLICIES_FILE")
    mac=$(printf '%s' "$rule" | jq -r '.mac // empty')
    ip=$(ss_mac_to_ip "$mac" 2>/dev/null || true)
    name=$(printf '%s' "$rule" | jq -r '.name // empty')
    [ -z "$name" ] && name=$(ss_mac_to_name "$mac" 2>/dev/null || true)
    jq --argjson rule "$rule" --arg ip "${ip:-}" --arg name "${name:-}" \
      '. + [$rule + (if $ip != "" then {ip:$ip} else {} end) + (if $name != "" then {name:$name} else {} end)]' \
      "$rules_tmp" >"$rules_tmp.n" && mv "$rules_tmp.n" "$rules_tmp"
    i=$((i + 1))
  done
  jq -n --slurpfile rules "$rules_tmp" --slurpfile pol "$SS_POLICIES_FILE" '
    {catchall: ($pol[0].catchall // true), rules: ($rules[0] // [])}
  ' >"$out"
  rm -f "$rules_tmp" "$rules_tmp.n"
}

ss_backup_index_update() {
  local name="$1"
  local manifest_json="$2"
  ss_ensure_dirs
  [ -f "$SS_BACKUP_INDEX" ] || echo '[]' >"$SS_BACKUP_INDEX"
  jq --arg name "$name" --argjson m "$manifest_json" '
    (map(select(.file != $name))) + [($m + {file:$name})] |
    sort_by(.created_at) | reverse
  ' "$SS_BACKUP_INDEX" >"$SS_BACKUP_INDEX.tmp" && mv "$SS_BACKUP_INDEX.tmp" "$SS_BACKUP_INDEX"
  ln -sf "$SS_BACKUP_INDEX" "$ADDON_WEB_DIR/backups.json" 2>/dev/null || true
}

ss_backup_rotate() {
  local keep="${1:-$SS_BACKUP_KEEP}"
  local n=0
  # Delete oldest beyond keep count
  ls -1t "$ADDON_BACKUP_DIR"/stealthsurf-backup-*.tar.gz 2>/dev/null | while read -r f; do
    n=$((n + 1))
    if [ "$n" -gt "$keep" ]; then
      rm -f "$f"
      base=$(basename "$f")
      if [ -f "$SS_BACKUP_INDEX" ]; then
        jq --arg name "$base" 'map(select(.file != $name))' "$SS_BACKUP_INDEX" >"$SS_BACKUP_INDEX.tmp" &&
          mv "$SS_BACKUP_INDEX.tmp" "$SS_BACKUP_INDEX"
      fi
      ss_activity "backup.rotate" "removed old backup $base"
    fi
  done
}

ss_backup() {
  local note="${1:-manual}"
  local stamp name out stage manifest clients_snap
  ss_ensure_dirs
  stamp=$(date +%Y%m%d-%H%M%S)
  name="stealthsurf-backup-${stamp}.tar.gz"
  out="$ADDON_BACKUP_DIR/$name"
  stage="$ADDON_TMP_DIR/backup-stage.$$"
  rm -rf "$stage"
  mkdir -p "$stage/stealthsurf-backup"

  ss_activity "backup.start" "note=${note}"

  # Snapshot LAN devices into backup
  if type ss_clientlist_json >/dev/null 2>&1; then
    ss_clientlist_json >"$stage/stealthsurf-backup/devices.json" 2>/dev/null || echo '[]' >"$stage/stealthsurf-backup/devices.json"
  else
    echo '[]' >"$stage/stealthsurf-backup/devices.json"
  fi

  ss_backup_enrich_policies "$stage/stealthsurf-backup/policies.json"

  # Copy configuration files
  for f in \
    "$SS_CONF_FILE" \
    "$SS_ROUTING_FILE" \
    "$SS_OUTBOUNDS_FILE" \
    "$SS_CACHE_CONFIGS" \
    "$SS_CACHE_KEYS" \
    "$SS_CACHE_SUBSCRIPTIONS" \
    "$SS_CACHE_LOCATIONS" \
    "$SS_CACHE_PROFILE" \
    "$SS_CACHE_BALANCES" \
    "$SS_STATE_FILE" \
    "$SS_ENDPOINTS_FILE" \
    "$XRAY_CONFIG_FILE"; do
    [ -f "$f" ] || continue
    cp -f "$f" "$stage/stealthsurf-backup/$(basename "$f")" 2>/dev/null || true
  done

  # Also keep original policies filename
  [ -f "$SS_POLICIES_FILE" ] && cp -f "$SS_POLICIES_FILE" "$stage/stealthsurf-backup/policies.raw.json"

  manifest=$(ss_backup_manifest "$stamp" "$note")
  printf '%s\n' "$manifest" >"$stage/stealthsurf-backup/manifest.json"

  # README inside archive
  cat >"$stage/stealthsurf-backup/README.txt" <<EOF
StealthSurf configuration backup
Created: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
Version: $ADDON_VERSION
Note: $note

Restore on router:
  stealthsurf restore $out
EOF

  if tar -czf "$out" -C "$stage" stealthsurf-backup; then
    ss_backup_index_update "$name" "$manifest"
    ss_backup_rotate "$SS_BACKUP_KEEP"
    ss_activity "backup.done" "file=$name note=${note} size=$(wc -c <"$out" | tr -d ' ')"
    ss_ok "Backup written to $out"
    rm -rf "$stage"
    printf '%s\n' "$out"
    return 0
  fi

  ss_error "Backup failed"
  ss_activity "backup.fail" "note=${note}"
  rm -rf "$stage"
  return 1
}

ss_backup_auto() {
  # Quiet auto-backup before destructive/config-changing ops
  [ "${SS_AUTO_BACKUP:-1}" = "1" ] || return 0
  local reason="${1:-auto}"
  ss_backup "$reason" >/dev/null 2>&1 || ss_warn "Auto-backup ($reason) failed"
}

ss_backup_list() {
  ss_ensure_dirs
  [ -f "$SS_BACKUP_INDEX" ] || echo '[]' >"$SS_BACKUP_INDEX"
  # Refresh index from files on disk
  ls -1t "$ADDON_BACKUP_DIR"/stealthsurf-backup-*.tar.gz 2>/dev/null | while read -r f; do
    base=$(basename "$f")
    if ! jq -e --arg n "$base" 'any(.[]; .file == $n)' "$SS_BACKUP_INDEX" >/dev/null 2>&1; then
      jq --arg n "$base" --argjson ts "$(date -r "$f" +%s 2>/dev/null || date +%s)" \
        '. + [{file:$n, created_at:$ts, note:"discovered", version:""}]' \
        "$SS_BACKUP_INDEX" >"$SS_BACKUP_INDEX.tmp" && mv "$SS_BACKUP_INDEX.tmp" "$SS_BACKUP_INDEX"
    fi
  done
  jq 'sort_by(.created_at) | reverse' "$SS_BACKUP_INDEX"
}

ss_restore() {
  local archive="$1"
  local stage
  [ -f "$archive" ] || {
    # Allow basename from backup dir
    if [ -f "$ADDON_BACKUP_DIR/$archive" ]; then
      archive="$ADDON_BACKUP_DIR/$archive"
    else
      ss_error "usage: restore <backup.tar.gz|filename>"
      return 1
    fi
  }

  ss_activity "restore.start" "archive=$(basename "$archive")"
  ss_backup_auto "pre-restore" || true
  ss_stop 2>/dev/null || true

  stage="$ADDON_TMP_DIR/restore-stage.$$"
  rm -rf "$stage"
  mkdir -p "$stage"
  if ! tar -xzf "$archive" -C "$stage" 2>/dev/null; then
    ss_error "Cannot extract $archive"
    ss_activity "restore.fail" "extract failed"
    rm -rf "$stage"
    return 1
  fi

  # Support both layouts: stealthsurf-backup/* and flat
  local src="$stage/stealthsurf-backup"
  [ -d "$src" ] || src="$stage"

  ss_ensure_dirs
  [ -f "$src/stealthsurf.conf" ] && cp -f "$src/stealthsurf.conf" "$SS_CONF_FILE"
  [ -f "$src/routing.json" ] && cp -f "$src/routing.json" "$SS_ROUTING_FILE"
  [ -f "$src/outbounds.json" ] && cp -f "$src/outbounds.json" "$SS_OUTBOUNDS_FILE"
  [ -f "$src/policies.raw.json" ] && cp -f "$src/policies.raw.json" "$SS_POLICIES_FILE"
  [ ! -f "$SS_POLICIES_FILE" ] && [ -f "$src/policies.json" ] && cp -f "$src/policies.json" "$SS_POLICIES_FILE"
  [ -f "$src/configs.json" ] && cp -f "$src/configs.json" "$SS_CACHE_CONFIGS"
  [ -f "$src/api_keys.json" ] && cp -f "$src/api_keys.json" "$SS_CACHE_KEYS"
  [ -f "$src/subscriptions.json" ] && cp -f "$src/subscriptions.json" "$SS_CACHE_SUBSCRIPTIONS"
  [ -f "$src/locations.json" ] && cp -f "$src/locations.json" "$SS_CACHE_LOCATIONS"
  [ -f "$src/profile.json" ] && cp -f "$src/profile.json" "$SS_CACHE_PROFILE"
  [ -f "$src/balances.json" ] && cp -f "$src/balances.json" "$SS_CACHE_BALANCES"
  [ -f "$src/state.json" ] && cp -f "$src/state.json" "$SS_STATE_FILE"
  [ -f "$src/endpoints.json" ] && cp -f "$src/endpoints.json" "$SS_ENDPOINTS_FILE"
  [ -f "$src/stealthsurf.json" ] && cp -f "$src/stealthsurf.json" "$XRAY_CONFIG_FILE"

  if [ -f "$SS_CONF_FILE" ]; then
    # shellcheck disable=SC1090
    . "$SS_CONF_FILE"
  fi

  # Log restored device map if present
  if [ -f "$src/devices.json" ]; then
    ss_activity "restore.devices" "restored device snapshot count=$(jq 'length' "$src/devices.json" 2>/dev/null || echo 0)"
    jq -r '.[] | "ip=\(.ip // "-") mac=\(.mac // "-") name=\(.name // "-")"' "$src/devices.json" 2>/dev/null |
      while read -r line; do
        [ -n "$line" ] && ss_activity "restore.device" "$line"
      done
  fi

  rm -rf "$stage"
  ss_activity "restore.done" "archive=$(basename "$archive")"
  ss_ok "Restored from $archive — run start if needed"
}

ss_update_self() {
  # Atomic self-update: never delete the live addon until the new package is validated.
  # A failed download/extract previously wiped /jffs/addons/stealthsurf and left the UI gone.
  # Optional $1 = pinned download URL (used for install-version / rollback — no latest fallback).
  # Progress/status → stderr via ss_progress_* when interactive (SSH TTY / SS_PROGRESS=1).
  local tmp="/tmp/asuswrt-merlin-stealthsurf.tar.gz"
  local url=""
  local pinned="${1:-}"
  local new_ver=""
  local stage="/tmp/stealthsurf-update-stage.$$"
  local bak="/tmp/stealthsurf-update-bak.$$"
  local new_script=""

  if type ss_cli_force_progress >/dev/null 2>&1; then
    ss_cli_force_progress
  fi
  ss_progress_begin "StealthSurf update" 7
  if type ss_cli_echo >/dev/null 2>&1; then
    ss_cli_echo "Stages: backup → resolve URL → download → validate → install → remount → version"
  fi

  ss_progress_step "Backup before update"
  ss_backup_auto "pre-update" || true

  ss_progress_step "Checking GitHub / resolving download URL"
  if [ -n "$pinned" ] && [ "$pinned" != "null" ]; then
    url="$pinned"
  else
    # Resolve download URL from last check (or refresh)
    url=$(ss_version_download_url 2>/dev/null || echo "$ADDON_RELEASE_TGZ")
    if [ -z "$url" ] || [ "$url" = "null" ]; then
      url="$ADDON_RELEASE_TGZ"
    fi
    # If version.json is stale, refresh so we pick the release asset URL
    # Keep stderr free for progress (do not redirect 2>&1)
    if [ ! -f "$SS_VERSION_FILE" ] || ! jq -e '.download_url' "$SS_VERSION_FILE" >/dev/null 2>&1; then
      ss_version_check >/dev/null || true
      url=$(ss_version_download_url 2>/dev/null || echo "$ADDON_RELEASE_TGZ")
    fi
  fi
  ss_info "Download URL: $url"

  ss_progress_step "Downloading release"
  ss_info "Downloading release from $url …"
  ss_activity "update.start" "from=$url"
  if ! ss_curl_download "$url" "$tmp"; then
    if [ -n "$pinned" ]; then
      # Pinned tag/rollback must not silently install latest
      ss_error "Could not download pinned release tarball: $url"
      ss_activity "update.fail" "pinned download failed"
      ss_progress_end "update FAILED"
      return 1
    fi
    # Fallback to canonical latest/download URL
    ss_warn "Primary download failed, trying $ADDON_RELEASE_TGZ"
    if ! ss_curl_download "$ADDON_RELEASE_TGZ" "$tmp"; then
      ss_error "Could not download release tarball"
      ss_activity "update.fail" "download failed"
      ss_progress_end "update FAILED"
      return 1
    fi
  fi

  ss_progress_step "Validating archive"
  # Reject HTML error pages / empty files before touching live addon files
  if [ ! -s "$tmp" ] || ! tar -tzf "$tmp" >/dev/null 2>&1; then
    ss_error "Downloaded file is not a valid release archive (refusing to replace addon)"
    ss_activity "update.fail" "invalid archive"
    rm -f "$tmp"
    ss_progress_end "update FAILED"
    return 1
  fi

  ss_progress_step "Extracting and installing files"
  rm -rf "$stage" "$bak"
  mkdir -p "$stage" /jffs/addons /jffs/scripts
  if ! tar -xzf "$tmp" -C "$stage"; then
    ss_error "Failed to extract release archive (live addon untouched)"
    ss_activity "update.fail" "extract failed"
    rm -rf "$stage"
    rm -f "$tmp"
    ss_progress_end "update FAILED"
    return 1
  fi

  if [ ! -f "$stage/stealthsurf/stealthsurf" ] || [ ! -f "$stage/stealthsurf/index.asp" ] || [ ! -f "$stage/stealthsurf/app.js" ]; then
    ss_error "Invalid release archive layout (live addon untouched)"
    ss_activity "update.fail" "bad archive"
    rm -rf "$stage"
    rm -f "$tmp"
    ss_progress_end "update FAILED"
    return 1
  fi

  # Snapshot current files for rollback
  mkdir -p "$bak"
  [ -d "$ADDON_JFFS_ADN_DIR" ] && cp -a "$ADDON_JFFS_ADN_DIR" "$bak/addons" 2>/dev/null || true
  [ -f "$ADDON_SCRIPT" ] && cp -a "$ADDON_SCRIPT" "$bak/stealthsurf" 2>/dev/null || true

  # Swap in new addon dir
  rm -rf "$ADDON_JFFS_ADN_DIR"
  if ! mv "$stage/stealthsurf" "$ADDON_JFFS_ADN_DIR"; then
    ss_error "Failed to install extracted addon — restoring previous files"
    ss_activity "update.fail" "swap failed"
    [ -d "$bak/addons" ] && mv "$bak/addons" "$ADDON_JFFS_ADN_DIR" 2>/dev/null || true
    [ -f "$bak/stealthsurf" ] && cp -a "$bak/stealthsurf" "$ADDON_SCRIPT" 2>/dev/null || true
    rm -rf "$stage" "$bak"
    rm -f "$tmp"
    ss_progress_end "update FAILED"
    return 1
  fi

  new_script="$ADDON_JFFS_ADN_DIR/stealthsurf"
  if ! mv -f "$new_script" "$ADDON_SCRIPT"; then
    ss_error "Failed to replace CLI script — restoring previous files"
    ss_activity "update.fail" "script swap failed"
    rm -rf "$ADDON_JFFS_ADN_DIR"
    [ -d "$bak/addons" ] && mv "$bak/addons" "$ADDON_JFFS_ADN_DIR" 2>/dev/null || true
    [ -f "$bak/stealthsurf" ] && cp -a "$bak/stealthsurf" "$ADDON_SCRIPT" 2>/dev/null || true
    rm -rf "$stage" "$bak"
    rm -f "$tmp"
    ss_progress_end "update FAILED"
    return 1
  fi
  chmod 0755 "$ADDON_SCRIPT"
  rm -rf "$stage" "$bak"
  rm -f "$tmp"

  # Recreate CLI symlinks (Entware /opt may have been remounted)
  ln -sf "$ADDON_SCRIPT" "/opt/bin/$ADDON_TAG" 2>/dev/null || true
  ln -sf "$ADDON_SCRIPT" "/opt/bin/ssurf" 2>/dev/null || true

  ss_progress_step "Remounting UI / rewriting hooks"
  # Re-run install with NEW script (hooks, deps, mount UI, version.json)
  if ! sh "$ADDON_SCRIPT" install; then
    ss_warn "Post-update install reported errors — run: $ADDON_SCRIPT doctor"
  fi

  ss_progress_step "Refreshing version.json"
  # Refresh version after install (new ADDON_VERSION is inside new script; this shell still has old)
  # Silence JSON on stdout; keep stderr for nested status if TTY
  sh "$ADDON_SCRIPT" version >/dev/null || true
  sh "$ADDON_SCRIPT" check-update >/dev/null || true
  new_ver=$(jq -r '.installed // empty' "$SS_VERSION_FILE" 2>/dev/null)
  ss_activity "update.done" "installed=${new_ver:-ok}"
  ss_ok "Updated addon from GitHub Releases (now ${new_ver:-unknown}) — refresh WebUI / re-login"
  ss_progress_end "done — now ${new_ver:-unknown}"
}

ss_install_cron() {
  local sync_line watch_line backup_line
  sync_line="*/15 * * * * /jffs/scripts/$ADDON_TAG autosync >/dev/null 2>&1"
  # */10 keeps recovery reasonably fast without waking the ARM every 5 minutes
  watch_line="*/10 * * * * /jffs/scripts/$ADDON_TAG watchdog >/dev/null 2>&1"
  backup_line="0 3 * * * /jffs/scripts/$ADDON_TAG backup nightly >/dev/null 2>&1"

  if command -v cru >/dev/null 2>&1; then
    cru d stealthsurf_sync 2>/dev/null || true
    cru d stealthsurf_watch 2>/dev/null || true
    cru d stealthsurf_backup 2>/dev/null || true
    cru a stealthsurf_sync "*/15 * * * * /jffs/scripts/$ADDON_TAG autosync"
    cru a stealthsurf_watch "*/10 * * * * /jffs/scripts/$ADDON_TAG watchdog"
    if [ "${SS_AUTO_BACKUP:-1}" = "1" ]; then
      cru a stealthsurf_backup "0 3 * * * /jffs/scripts/$ADDON_TAG backup nightly"
    fi
    cru d stealthsurf_ver 2>/dev/null || true
    cru a stealthsurf_ver "15 */12 * * * /jffs/scripts/$ADDON_TAG check-update"
    if type ss_settings_install_extra_cron >/dev/null 2>&1; then
      ss_settings_install_extra_cron 2>/dev/null || true
    fi
    ss_ok "Cron jobs installed via cru (sync/watchdog/backup/version-check)"
    return 0
  fi

  local cronf="/var/spool/cron/crontabs/admin"
  local ver_line="15 */12 * * * /jffs/scripts/$ADDON_TAG check-update >/dev/null 2>&1"
  if [ -d "$(dirname "$cronf")" ]; then
    touch "$cronf"
    grep -q "$ADDON_TAG autosync" "$cronf" 2>/dev/null || echo "$sync_line" >>"$cronf"
    grep -q "$ADDON_TAG watchdog" "$cronf" 2>/dev/null || echo "$watch_line" >>"$cronf"
    if [ "${SS_AUTO_BACKUP:-1}" = "1" ]; then
      grep -q "$ADDON_TAG backup" "$cronf" 2>/dev/null || echo "$backup_line" >>"$cronf"
    fi
    grep -q "$ADDON_TAG check-update" "$cronf" 2>/dev/null || echo "$ver_line" >>"$cronf"
    if type ss_settings_install_extra_cron >/dev/null 2>&1; then
      ss_settings_install_extra_cron 2>/dev/null || true
    fi
    ss_ok "Cron lines appended to $cronf"
  else
    ss_warn "No cru/crontab — schedule autosync/backup manually"
  fi
}

ss_remove_cron() {
  if command -v cru >/dev/null 2>&1; then
    cru d stealthsurf_sync 2>/dev/null || true
    cru d stealthsurf_watch 2>/dev/null || true
    cru d stealthsurf_backup 2>/dev/null || true
    cru d stealthsurf_ver 2>/dev/null || true
    cru d stealthsurf_reboot 2>/dev/null || true
    cru d stealthsurf_geodata 2>/dev/null || true
    cru d stealthsurf_tg 2>/dev/null || true
  fi
}
