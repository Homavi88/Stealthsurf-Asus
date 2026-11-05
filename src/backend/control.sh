#!/bin/sh

ss_xray_running() {
  if [ -f "$XRAY_PIDFILE" ]; then
    local pid
    pid=$(cat "$XRAY_PIDFILE" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
  fi
  return 1
}

ss_write_state() {
  ss_ensure_dirs
  local mode
  mode=$(ss_fw_detect_mode 2>/dev/null || echo "${SS_MODE:-proxy}")
  jq -nc \
    --arg active "${SS_ACTIVE_CONFIG_ID}" \
    --arg mode "${SS_MODE}" \
    --arg proxy_mode "$mode" \
    --arg dns_mode "${SS_DNS_MODE}" \
    --arg default "${SS_DEFAULT_OUTBOUND}" \
    --arg enabled "${SS_ENABLED_OUTBOUNDS}" \
    --argjson running "$(ss_xray_running && echo true || echo false)" \
    --arg socks "${SS_SOCKS_PORT}" \
    --arg http "${SS_HTTP_PORT}" \
    --arg tproxy "${SS_TPROXY_PORT}" \
    --arg redirect "${SS_REDIRECT_PORT}" \
    --arg version "$ADDON_VERSION" \
    '{
      active_config_id: (if $active == "" then null else ($active|tonumber?) // $active end),
      mode: $mode,
      proxy_mode: $proxy_mode,
      dns_mode: $dns_mode,
      default_outbound: (if $default == "" then null else $default end),
      enabled_outbounds: (if $enabled == "" then [] else ($enabled|split(" ")|map(tonumber? // .)) end),
      running: $running,
      socks_port: ($socks|tonumber),
      http_port: ($http|tonumber),
      tproxy_port: ($tproxy|tonumber),
      redirect_port: ($redirect|tonumber),
      version: $version
    }' >"$SS_STATE_FILE"
  ln -sf "$SS_STATE_FILE" "$ADDON_WEB_DIR/state.json" 2>/dev/null || true
}

ss_apply_config_id() {
  # Enable this config as outbound (+ optionally sole default) and rebuild
  local config_id="$1"
  local sole="${2:-1}" # 1 = make this the only/default outbound (legacy UX)
  local entry link proto runtime

  [ -n "$config_id" ] || {
    ss_error "usage: apply <config_id>"
    return 1
  }
  ss_activity "apply.start" "config_id=$config_id sole=$sole"
  ss_backup_auto "pre-apply" || true

  entry=$(ss_cache_get_config "$config_id")
  if [ -z "$entry" ] || [ "$entry" = "null" ]; then
    ss_info "Config $config_id not in cache, syncing…"
    ss_api_sync_configs >/dev/null || return 1
    entry=$(ss_cache_get_config "$config_id")
  fi

  if [ -z "$entry" ] || [ "$entry" = "null" ]; then
    ss_error "Config id $config_id not found"
    return 1
  fi

  proto=$(printf '%s' "$entry" | jq -r '.protocol // "vless"')
  runtime=$(ss_protocol_runtime "$proto")
  if [ "$runtime" = "unsupported" ] || { [ "$runtime" != "xray" ] && ! ss_protocol_supported_on_router "$proto"; }; then
    ss_error "Протокол $proto не поддерживается на этом роутере (статус: в разработке / нет бинаря)"
    return 1
  fi

  link=$(printf '%s' "$entry" | jq -r '.connection_url // empty')
  if [ -z "$link" ]; then
    ss_error "Config $config_id has empty connection_url"
    return 1
  fi

  if [ "$sole" = "1" ]; then
    ss_set_enabled_outbounds "[$config_id]" "ss-$config_id" || return 1
  else
    ss_enable_outbound "$config_id" || return 1
  fi

  SS_ACTIVE_CONFIG_ID="$config_id"
  ss_save_conf

  # Non-xray runtimes
  if [ "$runtime" != "xray" ]; then
    ss_apply_protocol_config "$config_id" || return 1
  fi

  ss_rebuild_and_restart || {
    ss_activity "apply.fail" "config_id=$config_id proto=$proto"
    return 1
  }
  ss_activity "apply.done" "config_id=$config_id proto=$runtime tag=ss-$config_id"
  ss_ok "Applied config $config_id ($proto) as outbound ss-$config_id"
}

ss_rebuild_xray_config() {
  local full
  ss_ensure_dirs
  ss_ensure_xray || ss_warn "xray binary missing"

  # Start non-xray enabled outbounds first (bridges)
  local id entry proto runtime
  for id in $SS_ENABLED_OUTBOUNDS; do
    entry=$(ss_cache_get_config "$id" 2>/dev/null) || continue
    proto=$(printf '%s' "$entry" | jq -r '.protocol // "vless"')
    runtime=$(ss_protocol_runtime "$proto")
    if [ "$runtime" != "xray" ] && [ "$runtime" != "unsupported" ]; then
      ss_apply_protocol_config "$id" || ss_warn "Failed to start $runtime for $id"
    fi
  done

  if [ -z "$SS_ENABLED_OUTBOUNDS" ] && [ -n "$SS_ACTIVE_CONFIG_ID" ]; then
    full=$(ss_build_xray_config "$(ss_parse_link_to_outbound "$(ss_cache_get_config "$SS_ACTIVE_CONFIG_ID" | jq -r '.connection_url')")") || return 1
  else
    full=$(ss_build_xray_config_multi) || return 1
  fi

  printf '%s\n' "$full" >"$XRAY_CONFIG_FILE"
  ss_write_state
  return 0
}

ss_rebuild_and_restart() {
  ss_rebuild_xray_config || return 1
  if ! command -v xray >/dev/null 2>&1 && [ ! -x "$XRAY_BIN" ]; then
    ss_warn "xray binary not found — config written to $XRAY_CONFIG_FILE"
    return 0
  fi
  ss_restart
}

ss_start_inner() {
  ss_activity "start.begin" "mode=${SS_MODE} dns=${SS_DNS_MODE} enabled=${SS_ENABLED_OUTBOUNDS}"
  if [ ! -f "$XRAY_CONFIG_FILE" ]; then
    ss_error "No local Xray config. Run: stealthsurf apply <config_id> or rebuild"
    ss_activity "start.fail" "no xray config"
    return 1
  fi
  ss_ensure_xray || {
    ss_error "xray not installed"
    ss_activity "start.fail" "xray missing"
    return 1
  }
  [ -x "$XRAY_BIN" ] || XRAY_BIN=$(command -v xray)

  if ss_xray_running; then
    ss_info "Already running (pid $(cat "$XRAY_PIDFILE"))"
    ss_configure_firewall
    ss_log_devices_snapshot 2>/dev/null || true
    ss_write_state
    ss_activity "start.already" "pid=$(cat "$XRAY_PIDFILE")"
    return 0
  fi

  if ! "$XRAY_BIN" run -test -c "$XRAY_CONFIG_FILE" >/tmp/stealthsurf-xray-test.log 2>&1; then
    ss_error "Xray config test failed — see /tmp/stealthsurf-xray-test.log"
    ss_activity "start.fail" "config test failed"
    return 1
  fi

  "$XRAY_BIN" run -c "$XRAY_CONFIG_FILE" >/dev/null 2>&1 &
  echo $! >"$XRAY_PIDFILE"
  sleep 1
  if ss_xray_running; then
    ss_configure_firewall
    case "$SS_DNS_MODE" in
    OFF) ;;
    *)
      ss_dnsmasq_configure
      ss_dnsmasq_restart
      ;;
    esac
    ss_log_devices_snapshot 2>/dev/null || true
    ss_ok "Xray started (pid $(cat "$XRAY_PIDFILE")), mode=$(ss_fw_detect_mode)"
    ss_activity "start.done" "pid=$(cat "$XRAY_PIDFILE") mode=$(ss_fw_detect_mode)"
    ss_write_state
    return 0
  fi
  ss_error "Xray failed to stay up"
  ss_activity "start.fail" "process died"
  rm -f "$XRAY_PIDFILE"
  ss_write_state
  return 1
}

ss_stop_inner() {
  local pid=""
  [ -f "$XRAY_PIDFILE" ] && pid=$(cat "$XRAY_PIDFILE" 2>/dev/null)
  ss_activity "stop.begin" "pid=${pid:-none}"
  ss_cleanup_firewall 2>/dev/null
  ss_dnsmasq_cleanup 2>/dev/null
  ss_stop_all_runtimes 2>/dev/null

  if [ -f "$XRAY_PIDFILE" ]; then
    pid=$(cat "$XRAY_PIDFILE" 2>/dev/null)
    if [ -n "$pid" ]; then
      kill "$pid" 2>/dev/null
      sleep 1
      if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null
      fi
    fi
    rm -f "$XRAY_PIDFILE"
  fi
  # Do NOT killall xray — other addons may use it
  ss_ok "Stopped (firewall cleaned, our PID only)"
  ss_activity "stop.done" "firewall cleaned"
  ss_write_state
}

ss_start() {
  ss_with_lock lifecycle ss_start_inner
}

ss_stop() {
  ss_with_lock lifecycle ss_stop_inner
}

ss_restart_inner() {
  ss_stop_inner
  ss_start_inner
}

ss_restart() {
  ss_with_lock lifecycle ss_restart_inner
}

ss_status() {
  ss_write_state
  if [ -f "$SS_STATE_FILE" ]; then
    cat "$SS_STATE_FILE"
  else
    echo '{"running":false}'
  fi
}

ss_set_mode() {
  local mode="$1"
  case "$mode" in
  proxy | redirect | tproxy) ;;
  *)
    ss_error "mode must be proxy|redirect|tproxy"
    return 1
    ;;
  esac
  ss_backup_auto "pre-set-mode" || true
  ss_activity "mode.set" "from=${SS_MODE} to=${mode}"
  SS_MODE="$mode"
  SS_PROXY_MODE="$mode"
  ss_save_conf
  if ss_xray_running || [ -f "$XRAY_CONFIG_FILE" ]; then
    ss_rebuild_and_restart || return 1
  fi
  ss_ok "Mode set to $mode"
}
