#!/bin/sh

ss_get_webui_page() {
  local page i
  ADDON_USER_PAGE="none"
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    page="user$i.asp"
    if [ -f "/www/user/$page" ] || [ -L "/www/user/$page" ]; then
      if [ -L "/www/user/$page" ] && [ "$(readlink "/www/user/$page" 2>/dev/null)" = "$ADDON_JFFS_ADN_DIR/index.asp" ]; then
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

  ln -sf "$ADDON_JFFS_ADN_DIR/index.asp" "/www/user/$ADDON_USER_PAGE"
  echo "StealthSurf" >"/www/user/${ADDON_USER_PAGE%.asp}.title"

  if [ ! -f /tmp/menuTree.js ]; then
    cp /www/require/modules/menuTree.js /tmp/menuTree.js
  fi

  grep -v 'tabName: "StealthSurf"' /tmp/menuTree.js >/tmp/menuTree.ss.$$ 2>/dev/null || cp /tmp/menuTree.js /tmp/menuTree.ss.$$
  mv /tmp/menuTree.ss.$$ /tmp/menuTree.js

  sed '/index: "menu_VPN"/,/index:/ {
 /url:\s*"NULL",\s*tabName:\s*"__INHERIT__"/ i\
\ \ \ \ \ \ \ \ { url: "'"$ADDON_USER_PAGE"'", tabName: "StealthSurf" },
}' /tmp/menuTree.js >/tmp/menuTree.ss.$$ && mv /tmp/menuTree.ss.$$ /tmp/menuTree.js

  umount /www/require/modules/menuTree.js 2>/dev/null
  mount -o bind /tmp/menuTree.js /www/require/modules/menuTree.js

  ln -sf "$ADDON_SCRIPT" "/opt/bin/$ADDON_TAG" 2>/dev/null || true
  ln -sf "$ADDON_JFFS_ADN_DIR/app.js" "$ADDON_WEB_DIR/app.js"
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
  ss_get_webui_page
  if [ -n "$ADDON_USER_PAGE" ] && [ "$ADDON_USER_PAGE" != "none" ]; then
    rm -f "/www/user/$ADDON_USER_PAGE" "/www/user/${ADDON_USER_PAGE%.asp}.title"
  fi
  for f in /www/user/user*.asp; do
    [ -L "$f" ] || continue
    case "$(readlink "$f" 2>/dev/null)" in
    *stealthsurf*) rm -f "$f" "${f%.asp}.title" ;;
    esac
  done

  if [ -f /tmp/menuTree.js ]; then
    grep -v 'tabName: "StealthSurf"' /tmp/menuTree.js >/tmp/menuTree.ss.$$ && mv /tmp/menuTree.ss.$$ /tmp/menuTree.js
    umount /www/require/modules/menuTree.js 2>/dev/null
    mount -o bind /tmp/menuTree.js /www/require/modules/menuTree.js
  fi
  ss_ok "UI unmounted"
}
