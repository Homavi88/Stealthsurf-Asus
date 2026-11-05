#!/bin/sh

ss_check_jffs_ready() {
  if [ ! -d /jffs ]; then
    ss_error "/jffs not found — Asuswrt-Merlin with JFFS required"
    return 1
  fi
  if command -v nvram >/dev/null 2>&1; then
    if [ "$(nvram get jffs2_on 2>/dev/null)" = "0" ]; then
      ss_error "JFFS partition disabled (nvram jffs2_on=0). Enable under Administration → System"
      return 1
    fi
    if [ "$(nvram get jffs2_scripts 2>/dev/null)" = "0" ]; then
      ss_error "JFFS custom scripts DISABLED. Enable: Administration → System → Enable JFFS custom scripts = Yes, then reboot"
      return 1
    fi
  fi
  return 0
}

ss_require_entware() {
  if [ ! -d /opt ] || { [ ! -x /opt/bin/opkg ] && [ ! -x /opt/sbin/opkg ]; }; then
    ss_error "Entware is not installed. Install Entware via amtm first, then re-run: stealthsurf install"
    return 1
  fi
  export PATH="/opt/bin:/opt/sbin:/sbin:/bin:/usr/sbin:/usr/bin:$PATH"
  return 0
}

ss_install_opkg() {
  local pkg="$1"
  local critical="${2:-0}"
  if opkg list-installed 2>/dev/null | grep -q "^${pkg} "; then
    return 0
  fi
  ss_info "Installing $pkg…"
  if opkg install "$pkg" >/dev/null 2>&1; then
    ss_ok "Installed $pkg"
    return 0
  fi
  if [ "$critical" = "1" ]; then
    ss_error "Critical package $pkg failed to install"
    return 1
  fi
  ss_warn "Could not install $pkg (continuing)"
  return 0
}

ss_install_deps() {
  ss_require_entware || return 1
  if ! command -v opkg >/dev/null 2>&1; then
    ss_error "opkg not found in PATH"
    return 1
  fi
  opkg update >/dev/null 2>&1 || ss_warn "opkg update failed (continuing)"

  # Critical — same baseline as xrayui dataplane
  ss_install_opkg curl 1 || return 1
  ss_install_opkg jq 1 || return 1
  ss_install_opkg ca-certificates 1 || return 1

  # Dataplane helpers used by firewall / DNS / TPROXY
  for pkg in flock iptables ipset unzip coreutils-base64 openssl-util findutils; do
    ss_install_opkg "$pkg" 0
  done
  # Optional quality-of-life
  for pkg in logrotate net-tools-netstat; do
    ss_install_opkg "$pkg" 0
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
  elif ! head -n1 "$f" | grep -qx '#!/bin/sh'; then
    ss_warn "$f is missing #!/bin/sh shebang"
  fi
  if ! grep -qF "$match" "$f" 2>/dev/null; then
    printf '\n%s\n' "$line" >>"$f"
  fi
  chmod 0755 "$f" 2>/dev/null || true
}

ss_hook_scripts() {
  # services-start: mount UI early; autostart is fallback only
  ss_hook_line_ensure /jffs/scripts/services-start \
    "$ADDON_TAG mount_ui" \
    "/jffs/scripts/$ADDON_TAG mount_ui >/dev/null 2>&1 #stealthsurf"
  ss_hook_line_ensure /jffs/scripts/services-start \
    "$ADDON_TAG autostart" \
    "/jffs/scripts/$ADDON_TAG autostart >/dev/null 2>&1 #stealthsurf"

  # post-mount: Entware USB ready — primary startup (xrayui pattern)
  ss_hook_line_ensure /jffs/scripts/post-mount \
    "$ADDON_TAG startup" \
    "/jffs/scripts/$ADDON_TAG startup >/dev/null 2>&1 #stealthsurf"

  # nat-start / firewall-start / wan-start: restore transparent rules
  ss_hook_line_ensure /jffs/scripts/nat-start \
    "$ADDON_TAG firewall-restore" \
    "/jffs/scripts/$ADDON_TAG firewall-restore >/dev/null 2>&1 #stealthsurf"
  ss_hook_line_ensure /jffs/scripts/firewall-start \
    "$ADDON_TAG firewall-restore" \
    "/jffs/scripts/$ADDON_TAG firewall-restore >/dev/null 2>&1 #stealthsurf"
  ss_hook_line_ensure /jffs/scripts/wan-start \
    "$ADDON_TAG wan-up" \
    "/jffs/scripts/$ADDON_TAG wan-up >/dev/null 2>&1 #stealthsurf"

  # dnsmasq.postconf
  ss_hook_line_ensure /jffs/scripts/dnsmasq.postconf \
    "$ADDON_TAG dnsmasq-configure" \
    "/jffs/scripts/$ADDON_TAG dnsmasq-configure \"\$1\" >/dev/null 2>&1 #stealthsurf"
}

ss_remove_hook_scripts() {
  local f
  for f in /jffs/scripts/services-start /jffs/scripts/post-mount \
    /jffs/scripts/nat-start /jffs/scripts/firewall-start \
    /jffs/scripts/wan-start /jffs/scripts/dnsmasq.postconf; do
    [ -f "$f" ] || continue
    grep -v "$ADDON_TAG" "$f" >"$f.ss.$$" 2>/dev/null && mv "$f.ss.$$" "$f"
    chmod 0755 "$f" 2>/dev/null || true
  done
}

ss_install() {
  ss_check_jffs_ready || return 1
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

  ss_policies_init
  ss_load_outbounds_meta

  chmod 0755 "$ADDON_SCRIPT" 2>/dev/null
  ln -sf "$ADDON_SCRIPT" "/opt/bin/$ADDON_TAG" 2>/dev/null || true

  ss_hook_scripts
  ss_install_service_event_hook
  ss_install_cron
  ss_mount_ui
  ss_write_state
  ss_version_local >/dev/null 2>&1 || true
  ss_version_check >/dev/null 2>&1 || true
  ss_ok "$ADDON_TITLE $ADDON_VERSION installed. Open VPN → StealthSurf after re-login."
  ss_info "Hooks: services-start, post-mount, nat-start, firewall-start, wan-start, dnsmasq.postconf, service-event"
}

ss_uninstall() {
  # Full removal from the router: stop dataplane, strip hooks/cron/UI/files.
  ss_info "Full uninstall of $ADDON_TITLE…"
  ss_activity "uninstall.start" ""
  if type ss_stop_all_runtimes >/dev/null 2>&1; then
    ss_stop_all_runtimes 2>/dev/null || true
  fi
  ss_stop 2>/dev/null || true
  ss_desired_clear 2>/dev/null || true
  ss_cleanup_firewall 2>/dev/null || true
  ss_dnsmasq_cleanup 2>/dev/null || true
  ss_dnsmasq_restart 2>/dev/null || true
  ss_unmount_ui 2>/dev/null || true
  ss_remove_service_event_hook 2>/dev/null || true
  ss_remove_hook_scripts 2>/dev/null || true
  ss_remove_cron 2>/dev/null || true

  # Symlinks and addon-owned paths
  rm -f "/opt/bin/$ADDON_TAG"
  rm -f "/opt/sbin/$ADDON_TAG" 2>/dev/null
  rm -rf "$ADDON_JFFS_ADN_DIR" "$ADDON_SHARE_DIR" "$ADDON_WEB_DIR"
  rm -rf "$ADDON_BACKUP_DIR" 2>/dev/null
  rm -f "$XRAY_CONFIG_FILE" "$XRAY_PIDFILE"
  rm -f "$SS_CONF_FILE"
  rm -f "$ADDON_SCRIPT"
  rm -f /opt/etc/stealthsurf-hysteria.yaml* 2>/dev/null
  rm -rf /opt/etc/stealthsurf-wg 2>/dev/null
  rm -f "$SS_DESIRED_STATE_FILE" "$SS_STARTUP_LOCK" 2>/dev/null
  rm -f /tmp/stealthsurf_payload.json /tmp/stealthsurf-service-event.log 2>/dev/null
  rm -f /tmp/stealthsurf.desired /tmp/stealthsurf.lock 2>/dev/null
  rm -f /tmp/stealthsurf-xray-test.log 2>/dev/null
  # Hysteria binary downloaded by the addon (leave shared Xray untouched)
  rm -f /opt/sbin/hysteria /opt/bin/hysteria 2>/dev/null

  # Menu entry leftovers under www user
  rm -rf "/www/user/$ADDON_TAG" 2>/dev/null

  ss_activity "uninstall.done" "full"
  ss_ok "Fully uninstalled $ADDON_TITLE (hooks, cron, UI, data, iptables cleaned)"
  ss_info "Xray binary under /opt was left in place (may be shared). Remove manually if unused."
}
