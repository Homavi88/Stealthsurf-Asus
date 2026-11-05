#!/bin/sh

# Merlin custom_settings / httpd service hooks call:
#   stealthsurf service_event <action> [arg]
# Payload JSON may be posted by the ASP page into /tmp/stealthsurf_payload.json

ss_read_payload() {
  local f="/tmp/stealthsurf_payload.json"
  local custom
  if [ -f "$f" ]; then
    if jq -e . "$f" >/dev/null 2>&1; then
      cat "$f"
      return 0
    fi
  fi
  custom=$(nvram get amng_custom 2>/dev/null)
  if [ -n "$custom" ] && printf '%s' "$custom" | jq -e . >/dev/null 2>&1; then
    printf '%s' "$custom" >"$f"
    printf '%s' "$custom"
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
    ss_json_response true "ok" "$(jq -nc \
      --slurpfile state "$SS_STATE_FILE" \
      --slurpfile outbounds "$SS_OUTBOUNDS_FILE" \
      --slurpfile routing "$SS_ROUTING_FILE" \
      --slurpfile policies "$SS_POLICIES_FILE" \
      --argjson protocols "$(ss_protocol_status_matrix)" \
      --arg has_key "$( [ -n "$SS_API_KEY" ] && echo true || echo false )" \
      '{
        state: ($state[0] // {}),
        outbounds: ($outbounds[0] // {}),
        routing: ($routing[0] // {}),
        policies: ($policies[0] // {}),
        protocols: $protocols,
        has_api_key: ($has_key == "true")
      }')"
    ;;
  setkey)
    SS_API_KEY=$(printf '%s' "$payload" | jq -r '.api_key // empty')
    if [ -z "$SS_API_KEY" ]; then
      ss_json_response false "api_key missing" null
      return 1
    fi
    ss_save_conf
    if ss_api_verify_key >/dev/null; then
      ss_json_response true "API key saved" "$(cat "$SS_CACHE_PROFILE")"
    else
      ss_json_response false "API key rejected" null
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
    if ss_api_sync_all >/dev/null; then
      ss_json_response true "synced" "$(jq -nc \
        --slurpfile configs "$SS_CACHE_CONFIGS" \
        --slurpfile locations "$SS_CACHE_LOCATIONS" \
        --slurpfile subs "$SS_CACHE_SUBSCRIPTIONS" \
        '{configs: ($configs[0] // []), locations: ($locations[0] // []), subscriptions: ($subs[0] // [])}')"
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
    ss_enable_outbound "$id" && ss_rebuild_and_restart
    ss_json_response true "enabled $id" "$(cat "$SS_OUTBOUNDS_FILE")"
    ;;
  disableoutbound)
    local id
    id=$(printf '%s' "$payload" | jq -r '.config_id // empty')
    ss_disable_outbound "$id" && ss_rebuild_and_restart
    ss_json_response true "disabled $id" "$(cat "$SS_OUTBOUNDS_FILE")"
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
      # Re-apply if this outbound is enabled
      if echo " $SS_ENABLED_OUTBOUNDS " | grep -q " $id "; then
        ss_rebuild_and_restart || true
      fi
      ss_json_response true "settings updated" "$(cat "$SS_CACHE_CONFIGS")"
    else
      ss_json_response false "settings update failed" null
      return 1
    fi
    ;;
  start)
    ss_start && ss_json_response true "started" "$(cat "$SS_STATE_FILE")" || ss_json_response false "start failed" null
    ;;
  stop)
    ss_stop && ss_json_response true "stopped" "$(cat "$SS_STATE_FILE")" || ss_json_response false "stop failed" null
    ;;
  restart)
    ss_restart && ss_json_response true "restarted" "$(cat "$SS_STATE_FILE")" || ss_json_response false "restart failed" null
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
    local via
    via=$(printf '%s' "$payload" | jq -r '.via // "socks"')
    ss_json_response true "connectivity" "$(ss_connectivity_check "" "$via")"
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
  update)
    if ss_update_self; then
      ss_json_response true "updated" null
    else
      ss_json_response false "update failed" null
    fi
    ;;
  geodata)
    ss_geodata_update && ss_json_response true "geodata updated" null || ss_json_response false "geodata failed" null
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
