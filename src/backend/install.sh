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
  # best-effort extras used by installer/dataplane
  for pkg in flock coreutils-base64 openssl-util; do
    if ! opkg list-installed 2>/dev/null | grep -q "^$pkg "; then
      opkg install "$pkg" >/dev/null 2>&1 || true
    fi
  done
}

ss_hook_scripts() {
  local services="/jffs/scripts/services-start"
  local line="/jffs/scripts/$ADDON_TAG mount_ui >/dev/null 2>&1"

  if [ ! -f "$services" ]; then
    printf '#!/bin/sh\n' >"$services"
    chmod 0755 "$services"
  fi
  if ! grep -qF "$ADDON_TAG mount_ui" "$services" 2>/dev/null; then
    printf '\n%s\n' "$line" >>"$services"
  fi
}

ss_install() {
  ss_ensure_dirs
  ss_install_deps || return 1

  if [ ! -f "$SS_CONF_FILE" ]; then
    SS_API_KEY=""
    SS_ACTIVE_CONFIG_ID=""
    ss_save_conf
  fi

  chmod 0755 "$ADDON_SCRIPT" 2>/dev/null
  ln -sf "$ADDON_SCRIPT" "/opt/bin/$ADDON_TAG" 2>/dev/null || true

  ss_hook_scripts
  ss_install_service_event_hook
  ss_mount_ui
  ss_write_state
  ss_ok "$ADDON_TITLE $ADDON_VERSION installed. Open VPN → StealthSurf after re-login."
}

ss_uninstall() {
  ss_stop 2>/dev/null
  ss_unmount_ui 2>/dev/null
  ss_remove_service_event_hook 2>/dev/null

  rm -f "/opt/bin/$ADDON_TAG"
  rm -rf "$ADDON_JFFS_ADN_DIR" "$ADDON_SHARE_DIR" "$ADDON_WEB_DIR"
  rm -f "$XRAY_CONFIG_FILE" "$XRAY_PIDFILE"
  # keep SS_CONF_FILE unless user wants wipe — remove it for clean uninstall
  rm -f "$SS_CONF_FILE"
  rm -f "$ADDON_SCRIPT"

  if [ -f /jffs/scripts/services-start ]; then
    grep -v "$ADDON_TAG mount_ui" /jffs/scripts/services-start >/tmp/services-start.$$ 2>/dev/null &&
      mv /tmp/services-start.$$ /jffs/scripts/services-start
  fi

  ss_ok "Uninstalled $ADDON_TITLE"
}
