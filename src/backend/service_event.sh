#!/bin/sh

# Merlin custom_settings / httpd service hooks call:
#   stealthsurf service_event <action> [arg]
# Payload JSON may be posted by the ASP page into /tmp/stealthsurf_payload.json

ss_am_settings_get() {
  # Read one flat key from Merlin /jffs/addons/custom_settings.txt
  local key="$1"
  local settings="/jffs/addons/custom_settings.txt"
  [ -f "$settings" ] || return 0
  grep -E "^${key} " "$settings" 2>/dev/null | head -1 | cut -f2- -d ' '
}

ss_clear_ui_payload_settings() {
  # Drop transient UI payload keys so API keys do not linger in custom_settings.txt
  local settings="/jffs/addons/custom_settings.txt"
  local tmp
  [ -f "$settings" ] || return 0
  grep -qE '^stealthsurf_payload|^stealthsurf ' "$settings" 2>/dev/null || return 0
  tmp="$settings.ss.$$"
  grep -vE '^stealthsurf_payload([0-9]+)? |^stealthsurf ' "$settings" >"$tmp" 2>/dev/null && mv -f "$tmp" "$settings"
  rm -f "$tmp" 2>/dev/null || true
}

ss_normalize_payload_json() {
  # Accept either flat action JSON or legacy {stealthsurf:{...}} wrapper
  local raw="$1"
  if printf '%s' "$raw" | jq -e 'has("stealthsurf")' >/dev/null 2>&1; then
    printf '%s' "$raw" | jq -c '.stealthsurf // {}'
  else
    printf '%s' "$raw" | jq -c .
  fi
}

ss_read_payload() {
  # Merlin httpd write_custom_settings() stores amng_custom into
  # /jffs/addons/custom_settings.txt as FLAT strings — it does NOT nvram_set
  # amng_custom. UI writes action JSON as stealthsurf_payload / stealthsurf_payloadN
  # (same idea as XrayUI xray_payload*). Fall back to legacy nvram / tmp file.
  local f="/tmp/stealthsurf_payload.json"
  local custom extracted payload_raw="" chunk idx

  payload_raw=$(ss_am_settings_get stealthsurf_payload)
  if [ -z "$payload_raw" ]; then
    idx=0
    while [ "$idx" -le 20 ]; do
      chunk=$(ss_am_settings_get "stealthsurf_payload${idx}")
      [ -n "$chunk" ] || break
      payload_raw="${payload_raw}${chunk}"
      idx=$((idx + 1))
    done
  fi

  if [ -n "$payload_raw" ] && printf '%s' "$payload_raw" | jq -e . >/dev/null 2>&1; then
    extracted=$(ss_normalize_payload_json "$payload_raw")
    printf '%s' "$extracted" >"$f"
    ss_clear_ui_payload_settings
    printf '%s' "$extracted"
    return 0
  fi

  custom=$(nvram get amng_custom 2>/dev/null)
  if [ -n "$custom" ] && printf '%s' "$custom" | jq -e . >/dev/null 2>&1; then
    extracted=$(ss_normalize_payload_json "$custom")
    printf '%s' "$extracted" >"$f"
    printf '%s' "$extracted"
    return 0
  fi

  if [ -f "$f" ] && jq -e . "$f" >/dev/null 2>&1; then
    ss_normalize_payload_json "$(cat "$f")"
    return 0
  fi
  echo '{}'
}

ss_service_event() {
  local action="$1"
  local arg="$2"
  local payload
  payload=$(ss_read_payload)

  case "$action" in
  init)
    ss_write_state
    ss_version_local >/dev/null 2>&1 || true
    # Soft auto-check (best-effort, non-fatal)
    ss_version_check >/dev/null 2>&1 || true
    ss_json_response true "ok" "$(jq -nc \
      --slurpfile state "$SS_STATE_FILE" \
      --slurpfile outbounds "$SS_OUTBOUNDS_FILE" \
      --slurpfile routing "$SS_ROUTING_FILE" \
      --slurpfile policies "$SS_POLICIES_FILE" \
      --slurpfile version "$SS_VERSION_FILE" \
      --argjson protocols "$(ss_protocol_status_matrix)" \
      --arg has_key "$( [ -n "$SS_API_KEY" ] && echo true || echo false )" \
      '{
        state: ($state[0] // {}),
        outbounds: ($outbounds[0] // {}),
        routing: ($routing[0] // {}),
        policies: ($policies[0] // {}),
        version: ($version[0] // {installed:"'"$ADDON_VERSION"'"}),
        protocols: $protocols,
        has_api_key: ($has_key == "true")
      }')"
    ;;
  checkupdate)
    if ss_version_check >/dev/null; then
      ss_json_response true "version checked" "$(cat "$SS_VERSION_FILE")"
    else
      ss_json_response false "version check failed" "$(ss_jq_file_or "$SS_VERSION_FILE" '{}')"
    fi
    ;;
  listversions | versions)
    if ss_version_list >/dev/null; then
      ss_json_response true "versions listed" "$(ss_jq_file_or "$SS_VERSIONS_FILE" '{}')"
    else
      ss_json_response false "versions list failed" "$(ss_jq_file_or "$SS_VERSIONS_FILE" '{}')"
    fi
    ;;
  installversion | switchversion | rollback)
    # Install a chosen GitHub release tag (upgrade or rollback). Payload: {tag:"v1.0.16"}
    local tag force_tag rc
    tag=$(printf '%s' "$payload" | jq -r '.tag // .version // empty')
    force_tag=$(printf '%s' "$payload" | jq -r '.force // "0"')
    if [ -z "$tag" ]; then
      ss_json_response false "tag missing" null
      return 1
    fi
    ss_activity "ui.installversion" "tag=$tag force=$force_tag"
    SS_FORCE_TAG="$force_tag"
    export SS_FORCE_TAG
    ss_version_install_tag "$tag"
    rc=$?
    if [ -x "$ADDON_SCRIPT" ]; then
      sh "$ADDON_SCRIPT" version >/dev/null 2>&1 || true
    fi
    case $rc in
    0) ss_json_response true "updated" "$(ss_jq_file_or "$SS_VERSION_FILE" '{}')" ;;
    2) ss_json_response true "already on version" "$(ss_jq_file_or "$SS_VERSION_FILE" '{}')" ;;
    *) ss_json_response false "install version failed" "$(ss_jq_file_or "$SS_VERSION_FILE" '{}')" ;;
    esac
    unset SS_FORCE_TAG
    ;;
  setkey)
    SS_API_KEY=$(printf '%s' "$payload" | jq -r '.api_key // empty')
    if [ -z "$SS_API_KEY" ]; then
      ss_json_response false "api_key missing" null
      return 1
    fi
    # Persist first so UI / conf keep the key even if API is briefly unreachable
    ss_ensure_dirs
    ss_api_keys_store_add "$SS_API_KEY" "primary"
    SS_API_KEYS=$(jq -r '.[].key' "$SS_CACHE_KEYS" 2>/dev/null | tr '\n' ' ')
    ss_save_conf
    if ss_api_verify_key >/dev/null; then
      ss_json_response true "API key saved" "$(ss_jq_file_or "$SS_CACHE_PROFILE" '{}')"
    else
      ss_json_response false "API key saved locally but verify failed (check internet / key)" "$(ss_jq_file_or "$SS_CACHE_KEYS" '[]')"
      return 1
    fi
    ;;
  addkey)
    local key label
    key=$(printf '%s' "$payload" | jq -r '.api_key // empty')
    label=$(printf '%s' "$payload" | jq -r '.label // empty')
    if ss_api_add_key "$key" "$label"; then
      ss_json_response true "key added" "$(cat "$SS_CACHE_KEYS")"
    else
      ss_json_response false "add key failed" null
      return 1
    fi
    ;;
  removekey)
    local key
    key=$(printf '%s' "$payload" | jq -r '.api_key // empty')
    ss_api_keys_store_remove "$key"
    ss_json_response true "key removed" "$(cat "$SS_CACHE_KEYS")"
    ;;
  sync)
    # Pull from StealthSurf API and rebuild dataplane if enabled configs changed
    if ss_sync_from_provider >/dev/null; then
      ss_json_response true "synced" "$(jq -nc \
        --slurpfile configs "$SS_CACHE_CONFIGS" \
        --slurpfile locations "$SS_CACHE_LOCATIONS" \
        --slurpfile subs "$SS_CACHE_SUBSCRIPTIONS" \
        --slurpfile state "$SS_STATE_FILE" \
        '{configs: ($configs[0] // []), locations: ($locations[0] // []), subscriptions: ($subs[0] // []), state: ($state[0] // {})}')"
    else
      ss_json_response false "sync failed" null
      return 1
    fi
    ;;
  apply)
    local id sole
    id=$(printf '%s' "$payload" | jq -r '.config_id // empty')
    sole=$(printf '%s' "$payload" | jq -r '.sole // "1"')
    [ -n "$id" ] || id="$arg"
    if ss_apply_config_id "$id" "$sole"; then
      ss_json_response true "applied $id" "$(cat "$SS_STATE_FILE")"
    else
      ss_json_response false "apply failed" null
      return 1
    fi
    ;;
  enableoutbound)
    local id
    id=$(printf '%s' "$payload" | jq -r '.config_id // empty')
    if [ -z "$id" ] || [ "$id" = "null" ]; then
      ss_json_response false "config_id required" null
      return 1
    fi
    if ss_enable_outbound "$id" && ss_rebuild_and_restart; then
      ss_json_response true "enabled $id" "$(cat "$SS_OUTBOUNDS_FILE")"
    else
      ss_json_response false "enable outbound failed" "$(ss_jq_file_or "$SS_OUTBOUNDS_FILE" '{}')"
      return 1
    fi
    ;;
  disableoutbound)
    local id
    id=$(printf '%s' "$payload" | jq -r '.config_id // empty')
    if [ -z "$id" ] || [ "$id" = "null" ]; then
      ss_json_response false "config_id required" null
      return 1
    fi
    if ss_disable_outbound "$id" && ss_rebuild_and_restart; then
      ss_json_response true "disabled $id" "$(cat "$SS_OUTBOUNDS_FILE")"
    else
      ss_json_response false "disable outbound failed" "$(ss_jq_file_or "$SS_OUTBOUNDS_FILE" '{}')"
      return 1
    fi
    ;;
  setdefault)
    local tag
    tag=$(printf '%s' "$payload" | jq -r '.outbound // .default // empty')
    if ss_set_default_outbound "$tag" && ss_rebuild_and_restart; then
      ss_json_response true "default=$tag" "$(cat "$SS_OUTBOUNDS_FILE")"
    else
      ss_json_response false "setdefault failed" null
      return 1
    fi
    ;;
  setoutbounds)
    local enabled default
    enabled=$(printf '%s' "$payload" | jq -c '.enabled // []')
    default=$(printf '%s' "$payload" | jq -r '.default // empty')
    if ss_set_enabled_outbounds "$enabled" "$default" && ss_rebuild_and_restart; then
      ss_json_response true "outbounds updated" "$(cat "$SS_OUTBOUNDS_FILE")"
    else
      ss_json_response false "setoutbounds failed" null
      return 1
    fi
    ;;
  setrouting)
    local rules default preset
    rules=$(printf '%s' "$payload" | jq -c '.rules // []')
    default=$(printf '%s' "$payload" | jq -r '.default_outbound // .default // empty')
    preset=$(printf '%s' "$payload" | jq -r '.preset // empty')
    if ss_routing_set_rules "$rules" "$default" "$preset" && ss_rebuild_and_restart; then
      ss_json_response true "routing saved" "$(cat "$SS_ROUTING_FILE")"
    else
      ss_json_response false "routing invalid or apply failed" null
      return 1
    fi
    ;;
  preset)
    local preset def alt
    preset=$(printf '%s' "$payload" | jq -r '.preset // empty')
    def=$(printf '%s' "$payload" | jq -r '.default_id // empty')
    alt=$(printf '%s' "$payload" | jq -r '.alt_id // empty')
    if ss_routing_apply_preset "$preset" "$def" "$alt" && ss_rebuild_and_restart; then
      ss_json_response true "preset $preset" "$(cat "$SS_ROUTING_FILE")"
    else
      ss_json_response false "preset failed" null
      return 1
    fi
    ;;
  setpolicies)
    if ss_policies_set "$payload"; then
      if ss_xray_running; then
        ss_cleanup_firewall
        ss_configure_firewall
      fi
      ss_json_response true "policies saved" "$(cat "$SS_POLICIES_FILE")"
    else
      ss_json_response false "policies failed" null
      return 1
    fi
    ;;
  clients)
    ss_json_response true "clients" "$(ss_clientlist_json)"
    ;;
  setmode)
    local mode
    mode=$(printf '%s' "$payload" | jq -r '.mode // empty')
    if ss_set_mode "$mode"; then
      ss_json_response true "mode=$mode" "$(cat "$SS_STATE_FILE")"
    else
      ss_json_response false "setmode failed" null
      return 1
    fi
    ;;
  setdnsmode)
    local mode
    mode=$(printf '%s' "$payload" | jq -r '.dns_mode // .mode // empty')
    if ss_set_dns_mode "$mode"; then
      ss_json_response true "dns=$mode" "$(cat "$SS_STATE_FILE")"
    else
      ss_json_response false "setdnsmode failed" null
      return 1
    fi
    ;;
  updatesettings)
    local id body
    id=$(printf '%s' "$payload" | jq -r '.config_id // empty')
    body=$(printf '%s' "$payload" | jq -c '.settings // empty')
    if [ -z "$id" ] || [ -z "$body" ] || [ "$body" = "null" ]; then
      ss_json_response false "config_id and settings required" null
      return 1
    fi
    if ss_api_update_settings "$id" "$body" >/dev/null; then
      # ss_api_update_settings already syncs + rebuilds when this id is enabled
      ss_json_response true "settings updated" "$(cat "$SS_CACHE_CONFIGS")"
    else
      ss_json_response false "settings update failed" null
      return 1
    fi
    ;;
  start)
    if ss_xrayui_running; then
      ss_write_state
      ss_json_response false "$(ss_xrayui_conflict_message)" "$(cat "$SS_STATE_FILE")"
      return 1
    fi
    ss_start && ss_json_response true "started" "$(cat "$SS_STATE_FILE")" || ss_json_response false "start failed" "$(ss_jq_file_or "$SS_STATE_FILE" 'null')"
    ;;
  stop)
    ss_stop && ss_json_response true "stopped" "$(cat "$SS_STATE_FILE")" || ss_json_response false "stop failed" null
    ;;
  restart)
    if ss_xrayui_running; then
      ss_write_state
      ss_json_response false "$(ss_xrayui_conflict_message)" "$(cat "$SS_STATE_FILE")"
      return 1
    fi
    ss_restart && ss_json_response true "restarted" "$(cat "$SS_STATE_FILE")" || ss_json_response false "restart failed" "$(ss_jq_file_or "$SS_STATE_FILE" 'null')"
    ;;
  rebuild)
    if ss_xrayui_running; then
      ss_write_state
      ss_json_response false "$(ss_xrayui_conflict_message)" "$(cat "$SS_STATE_FILE")"
      return 1
    fi
    if ss_rebuild_and_restart; then
      ss_json_response true "rebuilt" "$(cat "$SS_STATE_FILE")"
    else
      ss_json_response false "rebuild failed" "$(ss_jq_file_or "$SS_STATE_FILE" 'null')"
      return 1
    fi
    ;;
  status)
    ss_status >/dev/null
    ss_json_response true "status" "$(cat "$SS_STATE_FILE")"
    ;;
  diag)
    ss_json_response true "diag" "$(ss_diag_dump)"
    ;;
  testconfig)
    if ss_test_xray_config >/dev/null; then
      ss_json_response true "config ok" null
    else
      ss_json_response false "config test failed" null
    fi
    ;;
  connectivity)
    local via result
    via=$(printf '%s' "$payload" | jq -r '.via // "socks"')
    if result=$(ss_connectivity_check "" "$via"); then
      ss_json_response true "connectivity" "$result"
    else
      ss_json_response false "connectivity failed" "$(jq -nc --arg via "$via" '{ok:false, via:$via}')"
    fi
    ;;
  logs)
    local kind lines
    kind=$(printf '%s' "$payload" | jq -r '.kind // "activity"')
    lines=$(printf '%s' "$payload" | jq -r '.lines // "150"')
    ss_json_response true "logs" "$(jq -nc --arg t "$(ss_tail_logs "$kind" "$lines")" --arg kind "$kind" '{text:$t, kind:$kind}')"
    ;;
  clearlogs)
    local kind
    kind=$(printf '%s' "$payload" | jq -r '.kind // "all"')
    ss_logs_clear "$kind" && ss_json_response true "logs cleared" null || ss_json_response false "clear failed" null
    ;;
  devicesnapshot)
    ss_log_devices_snapshot
    ss_json_response true "devices logged" "$(jq -nc --arg t "$(ss_tail_logs devices 80)" '{text:$t}')"
    ;;
  backup)
    local note path
    note=$(printf '%s' "$payload" | jq -r '.note // "manual"')
    path=$(ss_backup "$note")
    if [ -n "$path" ] && [ -f "$path" ]; then
      ss_json_response true "backup ok" "$(jq -nc --arg p "$path" --argjson list "$(ss_backup_list)" '{path:$p, backups:$list}')"
    else
      ss_json_response false "backup failed" null
    fi
    ;;
  backuplist)
    ss_json_response true "backups" "$(ss_backup_list)"
    ;;
  restore)
    local path
    path=$(printf '%s' "$payload" | jq -r '.path // .file // empty')
    if ss_restore "$path"; then
      ss_json_response true "restored" "$(jq -nc --arg p "$path" '{path:$p}')"
    else
      ss_json_response false "restore failed" null
    fi
    ;;
  update | upgrade)
    # force=1 → always reinstall latest; tag/version → install that release; else only when newer.
    # WebUI Update must pass tag from browser GitHub check — router curl often fails/blocks and
    # would otherwise return "already up to date" without downloading.
    local force tag rc
    force=$(printf '%s' "$payload" | jq -r '.force // "0"')
    tag=$(printf '%s' "$payload" | jq -r '.tag // .version // empty')
    ss_activity "ui.update" "force=$force tag=${tag:-}"
    if [ -n "$tag" ]; then
      SS_FORCE_TAG="$force"
      export SS_FORCE_TAG
      ss_version_install_tag "$tag"
      rc=$?
      # Post-install: re-read version.json written by NEW script (this shell still has old ADDON_VERSION)
      if [ -x "$ADDON_SCRIPT" ]; then
        sh "$ADDON_SCRIPT" version >/dev/null 2>&1 || true
      fi
      case $rc in
      0) ss_json_response true "updated" "$(ss_jq_file_or "$SS_VERSION_FILE" '{}')" ;;
      2) ss_json_response true "already on version" "$(ss_jq_file_or "$SS_VERSION_FILE" '{}')" ;;
      *) ss_json_response false "update failed" "$(ss_jq_file_or "$SS_VERSION_FILE" '{}')" ;;
      esac
      unset SS_FORCE_TAG
    elif [ "$force" = "1" ] || [ "$force" = "true" ]; then
      ss_version_check >/dev/null 2>&1 || true
      if ss_update_self; then
        if [ -x "$ADDON_SCRIPT" ]; then
          sh "$ADDON_SCRIPT" version >/dev/null 2>&1 || true
        fi
        ss_json_response true "updated" "$(ss_jq_file_or "$SS_VERSION_FILE" '{}')"
      else
        ss_json_response false "update failed" "$(ss_jq_file_or "$SS_VERSION_FILE" '{}')"
      fi
    else
      ss_version_update_if_available 0
      rc=$?
      if [ "$rc" -eq 0 ] && [ -x "$ADDON_SCRIPT" ]; then
        sh "$ADDON_SCRIPT" version >/dev/null 2>&1 || true
      fi
      case $rc in
      0) ss_json_response true "updated" "$(ss_jq_file_or "$SS_VERSION_FILE" '{}')" ;;
      2) ss_json_response true "already up to date" "$(ss_jq_file_or "$SS_VERSION_FILE" '{}')" ;;
      *) ss_json_response false "update failed" "$(ss_jq_file_or "$SS_VERSION_FILE" '{}')" ;;
      esac
    fi
    ;;
  uninstall | remove | purge)
    # Hard-block from WebUI service-event — full wipe only via CLI: ssurf un --yes
    ss_json_response false "uninstall disabled from WebUI; use: ssurf un --yes" null
    return 1
    ;;
  doctor | heal | fix)
    if ss_doctor >/dev/null; then
      ss_json_response true "doctor ok" "$(ss_jq_file_or "$SS_STATE_FILE" '{}')"
    else
      ss_json_response false "doctor failed" null
      return 1
    fi
    ;;
  geodata)
    ss_geodata_update && ss_json_response true "geodata updated" null || ss_json_response false "geodata failed" null
    ;;
  getsettings | settings)
    if type ss_settings_publish >/dev/null 2>&1; then
      ss_settings_publish 2>/dev/null || true
    fi
    ss_json_response true "settings" "$(ss_settings_json)"
    ;;
  setsettings)
    local applied
    if applied=$(ss_settings_apply "$payload"); then
      ss_json_response true "settings saved" "$applied"
    else
      ss_json_response false "settings failed" null
      return 1
    fi
    ;;
  installxray)
    ss_ensure_xray && ss_json_response true "xray ready" null || ss_json_response false "xray install failed" null
    ;;
  *)
    ss_json_response false "unknown action: $action" null
    return 1
    ;;
  esac
}
