#!/bin/sh
# Merlin lifecycle: wait for Entware/network, then mount UI + optional autostart
# Pattern from xrayui startup.sh / post-mount — USB Entware often not ready at services-start

SS_DESIRED_STATE_FILE="/tmp/${ADDON_TAG}.desired"
SS_STARTUP_LOCK="/tmp/${ADDON_TAG}.startup.lock"
SS_STARTUP_DELAY="${SS_STARTUP_DELAY:-8}"

ss_desired_mark() {
  echo 1 >"$SS_DESIRED_STATE_FILE" 2>/dev/null || true
}

ss_desired_clear() {
  rm -f "$SS_DESIRED_STATE_FILE"
}

ss_desired_is_set() {
  [ -f "$SS_DESIRED_STATE_FILE" ]
}

ss_wait_for_entware() {
  local tries=0
  while [ "$tries" -lt 30 ]; do
    if [ -x /opt/bin/opkg ] || [ -x /opt/sbin/opkg ] || [ -d /opt/bin ]; then
      export PATH="/opt/bin:/opt/sbin:/sbin:/bin:/usr/sbin:/usr/bin:$PATH"
      return 0
    fi
    tries=$((tries + 1))
    sleep 1
  done
  ss_warn "Entware (/opt) not ready after wait"
  return 1
}

ss_wait_for_network() {
  local tries=0
  local delay="${SS_STARTUP_DELAY:-8}"
  ss_info "Waiting ${delay}s for network/iptables…"
  while [ "$tries" -lt "$delay" ]; do
    if iptables -w -t nat -L -n >/dev/null 2>&1; then
      # Prefer having a default route, but don't hard-fail
      if ip route show default 2>/dev/null | grep -q .; then
        sleep 1
        return 0
      fi
    fi
    tries=$((tries + 1))
    sleep 1
  done
  ss_warn "Network/iptables still settling — continuing anyway"
  return 0
}

ss_sysctl_dataplane() {
  # ip_forward required for transparent proxy of LAN clients
  if [ -f /proc/sys/net/ipv4/ip_forward ]; then
    if [ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" != "1" ]; then
      echo 1 >/proc/sys/net/ipv4/ip_forward 2>/dev/null || true
      ss_info "Enabled net.ipv4.ip_forward"
    fi
  fi
  # WireGuard/gVisor outbound on some Merlin builds
  if [ -f /proc/sys/net/ipv4/conf/all/src_valid_mark ]; then
    if [ "$(cat /proc/sys/net/ipv4/conf/all/src_valid_mark 2>/dev/null)" != "1" ]; then
      echo 1 >/proc/sys/net/ipv4/conf/all/src_valid_mark 2>/dev/null || true
    fi
  fi
}

ss_prepare_runtime() {
  ss_sysctl_dataplane
  case "$(ss_fw_detect_mode 2>/dev/null || echo "$SS_MODE")" in
  tproxy)
    ulimit -Hn 65535 2>/dev/null || true
    ulimit -Sn 65535 2>/dev/null || true
    ;;
  esac
}

ss_startup() {
  # Called from post-mount (preferred) or services-start fallback
  local skipwait="${1:-}"
  if [ -f "$SS_STARTUP_LOCK" ]; then
    local lock_pid
    lock_pid=$(cat "$SS_STARTUP_LOCK" 2>/dev/null)
    if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
      ss_warn "Startup already in progress (PID $lock_pid)"
      return 0
    fi
    rm -f "$SS_STARTUP_LOCK"
  fi
  echo $$ >"$SS_STARTUP_LOCK"

  ss_activity "startup.begin" "skipwait=${skipwait:-0}"
  ss_wait_for_entware || true
  if [ "$skipwait" != "1" ]; then
    ss_wait_for_network
  fi

  ss_mount_ui 2>/dev/null || ss_warn "mount_ui during startup failed"
  ss_version_local >/dev/null 2>&1 || true

  if [ "${SS_AUTO_START:-1}" = "1" ] && [ -f "$XRAY_CONFIG_FILE" ]; then
    if ss_xrayui_running 2>/dev/null; then
      ss_warn "Autostart skipped — XrayUI is running (stop XrayUI to use StealthSurf)"
      ss_desired_clear 2>/dev/null || true
      ss_write_state 2>/dev/null || true
    else
      ss_desired_mark
      ss_prepare_runtime
      ss_start || ss_warn "Startup start failed"
    fi
  else
    ss_info "Autostart skipped (SS_AUTO_START=${SS_AUTO_START:-1} or no config)"
  fi

  rm -f "$SS_STARTUP_LOCK"
  ss_activity "startup.done" "ok"
}

ss_wan_up_hook() {
  # After WAN reconnect: restore firewall if dataplane should be up
  ss_activity "wan.up" "restoring firewall if needed"
  sleep 2
  if ss_desired_is_set || ss_xray_running; then
    if ss_xrayui_running 2>/dev/null; then
      ss_warn "WAN-up: XrayUI running — skipping StealthSurf restore/start"
      ss_desired_clear 2>/dev/null || true
      ss_cleanup_firewall 2>/dev/null || true
      ss_write_state 2>/dev/null || true
      return 0
    fi
    if ! ss_xray_running && [ -f "$XRAY_CONFIG_FILE" ] && [ "${SS_AUTO_START:-1}" = "1" ]; then
      ss_prepare_runtime
      ss_start || true
    else
      ss_restore_firewall
    fi
  fi
}
