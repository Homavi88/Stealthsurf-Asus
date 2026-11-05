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
  jq -nc \
    --arg active "${SS_ACTIVE_CONFIG_ID}" \
    --arg mode "${SS_MODE}" \
    --argjson running "$(ss_xray_running && echo true || echo false)" \
    --arg socks "${SS_SOCKS_PORT}" \
    --arg http "${SS_HTTP_PORT}" \
    --arg version "$ADDON_VERSION" \
    '{
      active_config_id: (if $active == "" then null else ($active|tonumber?) // $active end),
      mode: $mode,
      running: $running,
      socks_port: ($socks|tonumber),
      http_port: ($http|tonumber),
      version: $version
    }' >"$SS_STATE_FILE"
}

ss_apply_config_id() {
  local config_id="$1"
  local entry link outbound full

  [ -n "$config_id" ] || {
    ss_error "usage: apply <config_id>"
    return 1
  }

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

  link=$(printf '%s' "$entry" | jq -r '.connection_url // empty')
  if [ -z "$link" ]; then
    ss_error "Config $config_id has empty connection_url"
    return 1
  fi

  outbound=$(ss_parse_link_to_outbound "$link") || return 1
  full=$(ss_build_xray_config "$outbound") || return 1

  ss_ensure_dirs
  printf '%s\n' "$full" >"$XRAY_CONFIG_FILE"
  SS_ACTIVE_CONFIG_ID="$config_id"
  ss_save_conf
  ss_write_state

  if ! command -v xray >/dev/null 2>&1 && [ ! -x "$XRAY_BIN" ]; then
    ss_warn "xray binary not found — config written to $XRAY_CONFIG_FILE"
    ss_ok "Applied config $config_id (start skipped: no xray)"
    return 0
  fi

  ss_restart || return 1
  ss_ok "Applied and started config $config_id ($(printf '%s' "$entry" | jq -r '.protocol // "?"'))"
}

ss_start() {
  if [ ! -f "$XRAY_CONFIG_FILE" ]; then
    ss_error "No local Xray config. Run: stealthsurf apply <config_id>"
    return 1
  fi
  if [ ! -x "$XRAY_BIN" ] && ! command -v xray >/dev/null 2>&1; then
    ss_error "xray not installed. Place binary at /opt/sbin/xray or install via Entware."
    return 1
  fi
  [ -x "$XRAY_BIN" ] || XRAY_BIN=$(command -v xray)

  if ss_xray_running; then
    ss_info "Already running (pid $(cat "$XRAY_PIDFILE"))"
    ss_write_state
    return 0
  fi

  if ! "$XRAY_BIN" run -test -c "$XRAY_CONFIG_FILE" >/tmp/stealthsurf-xray-test.log 2>&1; then
    ss_error "Xray config test failed — see /tmp/stealthsurf-xray-test.log"
    return 1
  fi

  "$XRAY_BIN" run -c "$XRAY_CONFIG_FILE" >/dev/null 2>&1 &
  echo $! >"$XRAY_PIDFILE"
  sleep 1
  if ss_xray_running; then
    ss_ok "Xray started (pid $(cat "$XRAY_PIDFILE")), SOCKS :$SS_SOCKS_PORT HTTP :$SS_HTTP_PORT"
    ss_write_state
    return 0
  fi
  ss_error "Xray failed to stay up"
  rm -f "$XRAY_PIDFILE"
  ss_write_state
  return 1
}

ss_stop() {
  if [ -f "$XRAY_PIDFILE" ]; then
    local pid
    pid=$(cat "$XRAY_PIDFILE" 2>/dev/null)
    if [ -n "$pid" ]; then
      kill "$pid" 2>/dev/null
      sleep 1
      kill -9 "$pid" 2>/dev/null
    fi
    rm -f "$XRAY_PIDFILE"
  fi
  # best-effort cleanup of stray process started by us
  killall xray 2>/dev/null
  ss_ok "Stopped"
  ss_write_state
}

ss_restart() {
  ss_stop
  ss_start
}

ss_status() {
  ss_write_state
  if [ -f "$SS_STATE_FILE" ]; then
    cat "$SS_STATE_FILE"
  else
    echo '{"running":false}'
  fi
}
