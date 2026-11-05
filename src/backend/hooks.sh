#!/bin/sh

ss_service_event_line() {
  printf '%s\n' '# StealthSurf UI hook' \
    'if [ "$1" = "start" ] && echo "$2" | grep -q "^stealthsurf_"; then' \
    '  action="${2#stealthsurf_}"' \
    '  # Prefer payload file written by WebUI helper; fallback to amng_custom' \
    '  if [ ! -f /tmp/stealthsurf_payload.json ]; then' \
    '    nvram get amng_custom 2>/dev/null > /tmp/stealthsurf_payload.json' \
    '  fi' \
    '  /jffs/scripts/stealthsurf service_event "$action" >/dev/null 2>&1 &' \
    'fi'
}

ss_install_service_event_hook() {
  local f="/jffs/scripts/service-event"
  if [ ! -f "$f" ]; then
    printf '#!/bin/sh\n\n' >"$f"
    chmod 0755 "$f"
  fi
  if ! grep -q 'stealthsurf service_event' "$f" 2>/dev/null; then
    ss_service_event_line >>"$f"
  fi
}

ss_remove_service_event_hook() {
  local f="/jffs/scripts/service-event"
  [ -f "$f" ] || return 0
  # shellcheck disable=SC2016
  awk '
    /StealthSurf UI hook/ {skip=1; next}
    skip && /stealthsurf service_event/ {next}
    skip && /^fi$/ {skip=0; next}
    skip {next}
    {print}
  ' "$f" >"$f.tmp" && mv "$f.tmp" "$f"
}

ss_autostart() {
  # Called from services-start after mount_ui
  [ "${SS_AUTO_START:-1}" = "1" ] || return 0
  if [ -f "$XRAY_CONFIG_FILE" ]; then
    ss_info "Autostart: starting dataplane"
    ss_start || ss_warn "Autostart failed"
  fi
}

ss_firewall_restore_hook() {
  ss_restore_firewall
}

ss_dnsmasq_configure_hook() {
  ss_dnsmasq_configure "$1"
}
