#!/bin/sh

ss_is_our_webui_page() {
  # Detect StealthSurf page whether mounted as symlink or copied .asp
  local page="$1"
  local path="/www/user/$page"
  local title="/www/user/${page%.asp}.title"
  [ -e "$path" ] || [ -L "$path" ] || return 1
  if [ -L "$path" ]; then
    case "$(readlink "$path" 2>/dev/null)" in
    *stealthsurf*) return 0 ;;
    esac
  fi
  if [ -f "$title" ] && grep -q 'StealthSurf' "$title" 2>/dev/null; then
    return 0
  fi
  if [ -f "$path" ] && grep -q 'ss_custom_settings_data\|StealthSurf UI' "$path" 2>/dev/null; then
    return 0
  fi
  return 1
}

ss_get_webui_page() {
  local page i
  ADDON_USER_PAGE="none"
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    page="user$i.asp"
    if [ -f "/www/user/$page" ] || [ -L "/www/user/$page" ]; then
      if ss_is_our_webui_page "$page"; then
        ADDON_USER_PAGE="$page"
        return 0
      fi
      continue
    fi
    ADDON_USER_PAGE="$page"
    return 0
  done
  return 1
}

# Insert VPN → StealthSurf into bind-mounted menuTree.js.
# BusyBox sed has no `\s`; use awk so 3004/3006 both match `{url: "NULL", tabName: "__INHERIT__"}`.
ss_menutree_inject_tab() {
  local page="$1"
  local src="$2"
  local dest="$3"
  [ -n "$page" ] && [ -f "$src" ] || return 1
  awk -v page="$page" '
    /tabName: "StealthSurf"/ { next }
    /index: "menu_VPN"/ { in_vpn = 1 }
    in_vpn && /index:/ && $0 !~ /index: "menu_VPN"/ { in_vpn = 0 }
    in_vpn && /url:[[:space:]]*"NULL",[[:space:]]*tabName:[[:space:]]*"__INHERIT__"/ && !injected {
      print "        { url: \"" page "\", tabName: \"StealthSurf\" },"
      injected = 1
    }
    { print }
  ' "$src" >"$dest" || return 1
  grep -q 'tabName: "StealthSurf"' "$dest"
}

ss_mount_ui() {
  nvram get rc_support 2>/dev/null | grep -q am_addons || {
    ss_error "Firmware does not support am_addons"
    return 1
  }

  ss_get_webui_page || {
    ss_error "No free userN.asp slot for WebUI"
    return 1
  }

  mkdir -p /www/user "$ADDON_WEB_DIR" "$ADDON_JFFS_ADN_DIR"

  # Copy (not only symlink) so Merlin httpd always serves a real .asp with ASP tags processed,
  # and so we can bake the real userN.asp name into current_page (required by show_menu).
  cp -f "$ADDON_JFFS_ADN_DIR/index.asp" "/www/user/$ADDON_USER_PAGE"
  # Ensure show_menu() finds this page in menuTree (default placeholder is user1.asp)
  # Also bake ADDON_VERSION into script ?v= so browsers pick up new app.js after update.
  if command -v sed >/dev/null 2>&1; then
    sed -i "s/value=\"user1.asp\"/value=\"$ADDON_USER_PAGE\"/g" "/www/user/$ADDON_USER_PAGE" 2>/dev/null || true
    sed -i "s/__SS_VERSION__/${ADDON_VERSION}/g" "/www/user/$ADDON_USER_PAGE" 2>/dev/null || true
  fi
  echo "StealthSurf" >"/www/user/${ADDON_USER_PAGE%.asp}.title"

  if [ ! -f /tmp/menuTree.js ]; then
    cp /www/require/modules/menuTree.js /tmp/menuTree.js
    mount -o bind /tmp/menuTree.js /www/require/modules/menuTree.js 2>/dev/null || true
  fi

  grep -v 'tabName: "StealthSurf"' /tmp/menuTree.js >/tmp/menuTree.ss.$$ 2>/dev/null || cp /tmp/menuTree.js /tmp/menuTree.ss.$$
  if [ ! -s /tmp/menuTree.ss.$$ ]; then
    cp /tmp/menuTree.js /tmp/menuTree.ss.$$
  fi
  mv /tmp/menuTree.ss.$$ /tmp/menuTree.js

  if ss_menutree_inject_tab "$ADDON_USER_PAGE" /tmp/menuTree.js /tmp/menuTree.ss.$$; then
    mv /tmp/menuTree.ss.$$ /tmp/menuTree.js
  else
    rm -f /tmp/menuTree.ss.$$
    ss_warn "Could not insert VPN → StealthSurf into menuTree.js (page still at /www/user/$ADDON_USER_PAGE)"
  fi

  umount /www/require/modules/menuTree.js 2>/dev/null
  mount -o bind /tmp/menuTree.js /www/require/modules/menuTree.js

  # Recreate CLI symlinks every mount — /opt (Entware USB) may remount without them
  ln -sf "$ADDON_SCRIPT" "/opt/bin/$ADDON_TAG" 2>/dev/null || true
  ln -sf "$ADDON_SCRIPT" "/opt/bin/ssurf" 2>/dev/null || true
  ln -sf "$ADDON_JFFS_ADN_DIR/app.js" "$ADDON_WEB_DIR/app.js"
  ln -sf "$ADDON_JFFS_ADN_DIR/routing-suggest.js" "$ADDON_WEB_DIR/routing-suggest.js" 2>/dev/null || true
  ln -sf "$SS_CACHE_CONFIGS" "$ADDON_WEB_DIR/configs.json" 2>/dev/null || true
  ln -sf "$SS_CACHE_LOCATIONS" "$ADDON_WEB_DIR/locations.json" 2>/dev/null || true
  ln -sf "$SS_CACHE_SUBSCRIPTIONS" "$ADDON_WEB_DIR/subscriptions.json" 2>/dev/null || true
  ln -sf "$SS_CACHE_KEYS" "$ADDON_WEB_DIR/api_keys.json" 2>/dev/null || true
  ln -sf "$SS_STATE_FILE" "$ADDON_WEB_DIR/state.json" 2>/dev/null || true
  ln -sf "$SS_OUTBOUNDS_FILE" "$ADDON_WEB_DIR/outbounds.json" 2>/dev/null || true
  ln -sf "$SS_ROUTING_FILE" "$ADDON_WEB_DIR/routing.json" 2>/dev/null || true
  ln -sf "$SS_POLICIES_FILE" "$ADDON_WEB_DIR/policies.json" 2>/dev/null || true
  ln -sf "$SS_DIAG_FILE" "$ADDON_WEB_DIR/diag.json" 2>/dev/null || true
  ln -sf "$ADDON_LOGS_DIR/addon.log" "$ADDON_WEB_DIR/addon.log" 2>/dev/null || true
  ln -sf "$ADDON_LOGS_DIR/activity.log" "$ADDON_WEB_DIR/activity.log" 2>/dev/null || true
  ln -sf "$ADDON_LOGS_DIR/errors.log" "$ADDON_WEB_DIR/errors.log" 2>/dev/null || true
  ln -sf "$ADDON_LOGS_DIR/devices.log" "$ADDON_WEB_DIR/devices.log" 2>/dev/null || true
  ln -sf "$XRAY_ACCESS_LOG" "$ADDON_WEB_DIR/xray-access.log" 2>/dev/null || true
  ln -sf "$XRAY_ERROR_LOG" "$ADDON_WEB_DIR/xray-error.log" 2>/dev/null || true
  mkdir -p "$ADDON_BACKUP_DIR" 2>/dev/null || true
  [ -f "$ADDON_BACKUP_DIR/index.json" ] || echo '[]' >"$ADDON_BACKUP_DIR/index.json"
  ln -sf "$ADDON_BACKUP_DIR/index.json" "$ADDON_WEB_DIR/backups.json" 2>/dev/null || true
  # Ensure log files exist so /ext/stealthsurf/*.log is readable in UI
  mkdir -p "$ADDON_LOGS_DIR" 2>/dev/null || true
  for _lf in addon.log activity.log errors.log devices.log; do
    [ -f "$ADDON_LOGS_DIR/$_lf" ] || : >"$ADDON_LOGS_DIR/$_lf"
  done
  if type ss_version_local >/dev/null 2>&1; then
    ss_version_local >/dev/null 2>&1 || true
  fi
  ln -sf "$SS_VERSION_FILE" "$ADDON_WEB_DIR/version.json" 2>/dev/null || true
  if [ -f "$SS_VERSIONS_FILE" ]; then
    ln -sf "$SS_VERSIONS_FILE" "$ADDON_WEB_DIR/versions.json" 2>/dev/null || true
  fi
  if type ss_settings_publish >/dev/null 2>&1; then
    ss_settings_publish 2>/dev/null || true
  fi
  if type ss_protocol_status_matrix >/dev/null 2>&1; then
    ss_protocol_status_matrix >/dev/null 2>&1 || true
  fi
  ln -sf "$SS_UI_RESPONSE" "$ADDON_WEB_DIR/stealthsurf-response.json" 2>/dev/null || : >"$SS_UI_RESPONSE"

  # Helper CGI-like drop for payload (writable by httpd via tmp)
  : >/tmp/stealthsurf_payload.json
  chmod 666 /tmp/stealthsurf_payload.json 2>/dev/null || true

  ss_ok "Mounted UI as $ADDON_USER_PAGE"
}

ss_unmount_ui() {
  local f base
  ss_get_webui_page
  if [ -n "$ADDON_USER_PAGE" ] && [ "$ADDON_USER_PAGE" != "none" ]; then
    rm -f "/www/user/$ADDON_USER_PAGE" "/www/user/${ADDON_USER_PAGE%.asp}.title"
  fi
  for f in /www/user/user*.asp; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    base=$(basename "$f")
    if ss_is_our_webui_page "$base"; then
      rm -f "$f" "${f%.asp}.title"
    fi
  done

  if [ -f /tmp/menuTree.js ]; then
    grep -v 'tabName: "StealthSurf"' /tmp/menuTree.js >/tmp/menuTree.ss.$$ && mv /tmp/menuTree.ss.$$ /tmp/menuTree.js
    umount /www/require/modules/menuTree.js 2>/dev/null
    mount -o bind /tmp/menuTree.js /www/require/modules/menuTree.js
  fi
  ss_ok "UI unmounted"
}

ss_doctor() {
  # Recover after Entware remount, broken symlinks, or failed partial update
  ss_info "Doctor: checking StealthSurf install…"
  local ok=1
  if [ ! -f "$ADDON_SCRIPT" ]; then
    ss_error "Missing $ADDON_SCRIPT — reinstall via one-liner"
    return 1
  fi
  chmod 0755 "$ADDON_SCRIPT" 2>/dev/null || true
  if [ ! -f "$ADDON_JFFS_ADN_DIR/index.asp" ] || [ ! -f "$ADDON_JFFS_ADN_DIR/app.js" ]; then
    ss_error "UI files missing under $ADDON_JFFS_ADN_DIR — run: $ADDON_SCRIPT update -f  (or reinstall)"
    ok=0
  fi
  if [ ! -f "$ADDON_JFFS_ADN_DIR/routing-suggest.js" ]; then
    ss_warn "routing-suggest.js missing — domain/geosite autocomplete unavailable until update"
  fi
  ln -sf "$ADDON_SCRIPT" "/opt/bin/$ADDON_TAG" 2>/dev/null || ss_warn "Cannot link /opt/bin/$ADDON_TAG (Entware up?)"
  ln -sf "$ADDON_SCRIPT" "/opt/bin/ssurf" 2>/dev/null || ss_warn "Cannot link /opt/bin/ssurf (Entware up?)"
  ss_hook_scripts 2>/dev/null || true
  ss_install_service_event_hook 2>/dev/null || true
  ss_install_cron 2>/dev/null || true
  if ! ss_mount_ui; then
    ss_error "mount_ui failed"
    ok=0
  fi
  # If Xray is down but transparent rules remain — restore internet
  if ! ss_xray_running 2>/dev/null && ss_firewall_is_configured 2>/dev/null; then
    ss_warn "Doctor: orphan transparent firewall rules found — cleaning to restore internet"
    ss_cleanup_firewall 2>/dev/null || true
  fi
  # Hint if stuck in redirect/tproxy without working VPN
  case "${SS_MODE:-proxy}" in
  redirect | tproxy)
    if ! ss_xray_running 2>/dev/null; then
      ss_warn "Mode is $SS_MODE but Xray is stopped. To restore direct internet: ssurf mode proxy"
    fi
    ;;
  esac
  ss_write_state full 2>/dev/null || true
  if [ "$ok" = "1" ]; then
    ss_ok "Doctor: hooks, CLI symlinks and WebUI remounted. Re-login to WebUI if tab missing."
    ss_info "CLI: /jffs/scripts/stealthsurf  ·  ssurf  ·  stealthsurf"
    return 0
  fi
  ss_error "Doctor: some checks failed — see messages above"
  return 1
}
