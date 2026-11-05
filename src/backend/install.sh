#!/bin/sh

ss_require_entware() {
  if [ ! -d /opt ] || { [ ! -x /opt/bin/opkg ] && [ ! -x /opt/sbin/opkg ]; }; then
    ss_error "Entware is not installed. Install Entware via amtm first, then re-run: stealthsurf install"
    return 1
  fi
  export PATH="/opt/bin:/opt/sbin:/sbin:/bin:/usr/sbin:/usr/bin:$PATH"
  return 0
}

ss_install_deps() {
  ss_require_entware || return 1
  if ! command -v opkg >/dev/null 2>&1; then
    ss_error "opkg not found in PATH"
    return 1
  fi
  opkg update >/dev/null 2>&1 || ss_warn "opkg update failed (continuing)"
  for pkg in curl jq ca-certificates; do
    if ! opkg list-installed 2>/dev/null | grep -q "^$pkg "; then
      ss_info "Installing $pkg…"
      opkg install "$pkg" || ss_warn "Could not install $pkg"
    fi
  done
  for pkg in flock coreutils-base64 openssl-util unzip; do
    if ! opkg list-installed 2>/dev/null | grep -q "^$pkg "; then
      opkg install "$pkg" >/dev/null 2>&1 || true
    fi
  done
}

ss_hook_line_ensure() {
  # ss_hook_line_ensure <file> <match_grep> <line_to_append>
  local f="$1"
  local match="$2"
  local line="$3"
  if [ ! -f "$f" ]; then
    printf '#!/bin/sh\n' >"$f"
    chmod 0755 "$f"
  fi
  if ! grep -qF "$match" "$f" 2>/dev/null; then
    printf '\n%s\n' "$line" >>"$f"
  fi
}

ss_hook_scripts() {
  # services-start: mount UI + optional autostart
  ss_hook_line_ensure /jffs/scripts/services-start \
    "$ADDON_TAG mount_ui" \
    "/jffs/scripts/$ADDON_TAG mount_ui >/dev/null 2>&1"
  ss_hook_line_ensure /jffs/scripts/services-start \
    "$ADDON_TAG autostart" \
    "/jffs/scripts/$ADDON_TAG autostart >/dev/null 2>&1"

  # nat-start / firewall-start: restore transparent rules after WAN up / reboot
  ss_hook_line_ensure /jffs/scripts/nat-start \
    "$ADDON_TAG firewall-restore" \
    "/jffs/scripts/$ADDON_TAG firewall-restore >/dev/null 2>&1"
  ss_hook_line_ensure /jffs/scripts/firewall-start \
    "$ADDON_TAG firewall-restore" \
    "/jffs/scripts/$ADDON_TAG firewall-restore >/dev/null 2>&1"

  # dnsmasq.postconf
  local dpc="/jffs/scripts/dnsmasq.postconf"
  ss_hook_line_ensure "$dpc" \
    "$ADDON_TAG dnsmasq-configure" \
    "/jffs/scripts/$ADDON_TAG dnsmasq-configure \"\$1\" >/dev/null 2>&1"
}

ss_remove_hook_scripts() {
  local f
  for f in /jffs/scripts/services-start /jffs/scripts/nat-start /jffs/scripts/firewall-start /jffs/scripts/dnsmasq.postconf; do
    [ -f "$f" ] || continue
    grep -v "$ADDON_TAG" "$f" >"$f.ss.$$" 2>/dev/null && mv "$f.ss.$$" "$f"
  done
}

ss_install() {
  ss_ensure_dirs
  ss_install_deps || return 1
  ss_ensure_xray || ss_warn "Xray not installed yet — run: stealthsurf install-xray"
  ss_geodata_update || true

  if [ ! -f "$SS_CONF_FILE" ]; then
    SS_API_KEY=""
    SS_ACTIVE_CONFIG_ID=""
    SS_MODE="redirect"
    SS_PROXY_MODE="redirect"
    SS_DNS_MODE="OFF"
    SS_AUTO_START="1"
    ss_save_conf
  fi

  # Seed default JSON stores
  ss_policies_init
  ss_load_outbounds_meta

  chmod 0755 "$ADDON_SCRIPT" 2>/dev/null
  ln -sf "$ADDON_SCRIPT" "/opt/bin/$ADDON_TAG" 2>/dev/null || true

  ss_hook_scripts
  ss_install_service_event_hook
  ss_install_cron
  ss_mount_ui
  ss_write_state
  ss_ok "$ADDON_TITLE $ADDON_VERSION installed. Open VPN → StealthSurf after re-login."
}

ss_uninstall() {
  ss_stop 2>/dev/null
  ss_cleanup_firewall 2>/dev/null
  ss_dnsmasq_cleanup 2>/dev/null
  ss_unmount_ui 2>/dev/null
  ss_remove_service_event_hook 2>/dev/null
  ss_remove_hook_scripts 2>/dev/null
  ss_remove_cron 2>/dev/null

  rm -f "/opt/bin/$ADDON_TAG"
  rm -rf "$ADDON_JFFS_ADN_DIR" "$ADDON_SHARE_DIR" "$ADDON_WEB_DIR"
  rm -f "$XRAY_CONFIG_FILE" "$XRAY_PIDFILE"
  rm -f "$SS_CONF_FILE"
  rm -f "$ADDON_SCRIPT"
  rm -f /opt/etc/stealthsurf-hysteria.yaml* 2>/dev/null
  rm -rf /opt/etc/stealthsurf-wg 2>/dev/null

  ss_ok "Uninstalled $ADDON_TITLE (iptables cleaned)"
}
