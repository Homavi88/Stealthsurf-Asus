#!/bin/sh

ss_service_event_block() {
  # Always refresh amng_custom → payload so UI actions (checkupdate/update/…) see fresh JSON
  cat <<'EOF'
# StealthSurf UI hook begin
if [ "$1" = "start" ] && echo "$2" | grep -q "^stealthsurf_"; then
  action="${2#stealthsurf_}"
  custom=$(nvram get amng_custom 2>/dev/null)
  if [ -n "$custom" ]; then
    printf '%s\n' "$custom" > /tmp/stealthsurf_payload.json
  else
    echo '{}' > /tmp/stealthsurf_payload.json
  fi
  /jffs/scripts/stealthsurf service_event "$action" >/tmp/stealthsurf-service-event.log 2>&1 &
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
  awk '
    /StealthSurf UI hook begin/ {skip=1; next}
    /StealthSurf UI hook$/ {skip=1; next}
    skip && /StealthSurf UI hook end/ {skip=0; next}
    skip && /stealthsurf service_event/ {next}
    skip && /^fi$/ {skip=0; next}
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
