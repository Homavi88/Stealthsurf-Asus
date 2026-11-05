#!/bin/sh
# Diagnostics, connectivity check, logs helpers

ss_diag_dump() {
  ss_ensure_dirs
  local running mode arch
  running=false
  ss_xray_running && running=true
  mode=$(ss_fw_detect_mode 2>/dev/null || echo "$SS_MODE")
  arch=$(ss_detect_arch)

  jq -nc \
    --arg version "$ADDON_VERSION" \
    --arg arch "$arch" \
    --arg mode "$mode" \
    --arg dns "$SS_DNS_MODE" \
    --argjson running "$running" \
    --arg xray_bin "${XRAY_BIN:-}" \
    --arg xray_ver "$({ $XRAY_BIN version 2>/dev/null || true; } | head -1)" \
    --argjson protocols "$(ss_protocol_status_matrix)" \
    --argjson state "$(ss_jq_file_or "$SS_STATE_FILE" '{}')" \
    --argjson outbounds "$(ss_jq_file_or "$SS_OUTBOUNDS_FILE" '{}')" \
    --argjson routing "$(ss_jq_file_or "$SS_ROUTING_FILE" '{}')" \
    --argjson policies "$(ss_jq_file_or "$SS_POLICIES_FILE" '{}')" \
    --arg iptables "$(iptables -w -t nat -S "$SS_FW_CHAIN" 2>/dev/null | head -c 4000 || echo '')" \
    --arg iptables_mangle "$(iptables -w -t mangle -S "$SS_FW_CHAIN" 2>/dev/null | head -c 4000 || echo '')" \
    --arg ip_rule "$(ip rule list 2>/dev/null | head -c 2000 || echo '')" \
    --argjson endpoints "$(ss_jq_file_or "$SS_ENDPOINTS_FILE" '[]')" \
    '{
      version:$version, arch:$arch, mode:$mode, dns_mode:$dns, running:$running,
      xray:{bin:$xray_bin, version:$xray_ver},
      protocols:$protocols, state:$state, outbounds:$outbounds,
      routing:$routing, policies:$policies, endpoints:$endpoints,
      firewall:{nat:$iptables, mangle:$iptables_mangle, ip_rule:$ip_rule},
      ts:(now|floor)
    }' >"$SS_DIAG_FILE"
  cat "$SS_DIAG_FILE"
}

ss_test_xray_config() {
  if [ ! -f "$XRAY_CONFIG_FILE" ]; then
    ss_error "No Xray config at $XRAY_CONFIG_FILE"
    return 1
  fi
  ss_ensure_xray || return 1
  if "$XRAY_BIN" run -test -c "$XRAY_CONFIG_FILE" >/tmp/stealthsurf-xray-test.log 2>&1; then
    ss_ok "Xray config OK"
    return 0
  fi
  ss_error "Xray config test failed"
  cat /tmp/stealthsurf-xray-test.log
  return 1
}

ss_connectivity_check() {
  local url="${1:-https://api.ipify.org}"
  local via="${2:-}" # socks|direct
  local out
  if [ "$via" = "socks" ]; then
    out=$(curl -fsS --connect-timeout 10 --max-time 20 \
      --socks5-hostname "127.0.0.1:${SS_SOCKS_PORT}" "$url" 2>/dev/null) || {
      ss_error "SOCKS connectivity check failed"
      return 1
    }
  else
    out=$(curl -fsS --connect-timeout 10 --max-time 20 "$url" 2>/dev/null) || {
      ss_error "Direct connectivity check failed"
      return 1
    }
  fi
  jq -nc --arg ip "$out" --arg via "${via:-direct}" '{ip:$ip, via:$via, ok:true}'
}

ss_tail_logs() {
  local kind="${1:-addon}"
  local lines="${2:-100}"
  case "$kind" in
  access) tail -n "$lines" "$XRAY_ACCESS_LOG" 2>/dev/null || echo "(no access log)" ;;
  error) tail -n "$lines" "$XRAY_ERROR_LOG" 2>/dev/null || echo "(no error log)" ;;
  *) tail -n "$lines" "$ADDON_LOGS_DIR/addon.log" 2>/dev/null || echo "(no addon log)" ;;
  esac
}

ss_watchdog_tick() {
  # If watchdog enabled and xray should be running, restart on death; optional failover tag
  [ "$SS_WATCHDOG" = "1" ] || return 0
  [ -f "$XRAY_CONFIG_FILE" ] || return 0
  if ! ss_xray_running; then
    ss_warn "Watchdog: Xray not running — restarting"
    ss_start || {
      if [ -n "$SS_FALLBACK_OUTBOUND" ] && [ "$SS_FALLBACK_OUTBOUND" != "direct" ]; then
        ss_warn "Watchdog: trying fallback outbound $SS_FALLBACK_OUTBOUND"
      fi
      return 1
    }
  fi
}
