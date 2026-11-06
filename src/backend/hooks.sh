#!/bin/sh

ss_service_event_block() {
  # Merlin splits action_script as:
  #   start_FOO  → $1=start  $2=FOO
  #   FOO        → $1=""     $2=FOO   (same path XrayUI uses)
  # Match on $2 starting with stealthsurf_ — requiring $1=start alone drops all
  # UI actions that omit the start_ prefix (setkey/addkey/sync never ran).
  # Payload lives in /jffs/addons/custom_settings.txt (stealthsurf_payload*), NOT
  # nvram amng_custom — httpd never nvram_sets that field. ss_read_payload loads it.
  # Run in foreground so Merlin action_wait covers real work.
  cat <<'EOF'
# StealthSurf UI hook begin
if echo "$2" | grep -q "^stealthsurf_"; then
  action="${2#stealthsurf_}"
  case "$action" in
  uninstall|remove|purge)
    echo '{"status":false,"message":"uninstall blocked from WebUI"}' > /www/user/stealthsurf/stealthsurf-response.json 2>/dev/null
    ;;
  *)
    /jffs/scripts/stealthsurf service_event "$action" >/tmp/stealthsurf-service-event.log 2>&1
    ;;
  esac
fi
# StealthSurf UI hook end
EOF
}

ss_install_service_event_hook() {
  local f="/jffs/scripts/service-event"
  if [ ! -f "$f" ]; then
    printf '#!/bin/sh\n\n' >"$f"
    chmod 0755 "$f"
  fi
  # Replace previous StealthSurf block so payload handling stays current
  if grep -q 'StealthSurf UI hook' "$f" 2>/dev/null; then
    ss_remove_service_event_hook
  fi
  {
    printf '\n'
    ss_service_event_block
  } >>"$f"
  chmod 0755 "$f" 2>/dev/null || true
}

ss_remove_service_event_hook() {
  local f="/jffs/scripts/service-event"
  [ -f "$f" ] || return 0
  # Only clear skip on explicit end marker (not on inner `fi`)
  awk '
    /StealthSurf UI hook begin/ {skip=1; next}
    /# StealthSurf UI hook$/ {skip=1; next}
    skip && /StealthSurf UI hook end/ {skip=0; next}
    skip {next}
    {print}
  ' "$f" >"$f.tmp" && mv "$f.tmp" "$f"
  chmod 0755 "$f" 2>/dev/null || true
}

ss_autostart() {
  # Lightweight services-start path: only mount UI; real start is post-mount
  # (Entware on USB is often not ready yet). Keep as fallback if post-mount missing.
  [ "${SS_AUTO_START:-1}" = "1" ] || return 0
  if [ -x /opt/bin/opkg ] || [ -x /opt/sbin/xray ] || [ -x /opt/bin/xray ]; then
    if [ -f "$XRAY_CONFIG_FILE" ]; then
      if ss_xrayui_running 2>/dev/null; then
        ss_warn "Autostart skipped — XrayUI is running"
        ss_desired_clear 2>/dev/null || true
        return 0
      fi
      ss_info "Autostart (services-start fallback)"
      ss_desired_mark 2>/dev/null || true
      ss_start || ss_warn "Autostart failed"
    fi
  else
    ss_info "Autostart deferred — waiting for post-mount (Entware)"
  fi
}

ss_firewall_restore_hook() {
  ss_restore_firewall
}

ss_dnsmasq_configure_hook() {
  ss_dnsmasq_configure "$1"
}
