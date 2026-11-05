#!/bin/sh
# shellcheck disable=SC2034

export PATH="/opt/bin:/opt/sbin:/sbin:/bin:/usr/sbin:/usr/bin"
export LC_ALL=C
unset LD_LIBRARY_PATH

ADDON_TAG="stealthsurf"
ADDON_TAG_UPPER="STEALTHSURF"
ADDON_TITLE="StealthSurf"
ADDON_VERSION="0.1.0"

ADDON_WEB_DIR="/www/user/$ADDON_TAG"
ADDON_SCRIPT="/jffs/scripts/$ADDON_TAG"
ADDON_SHARE_DIR="/opt/share/$ADDON_TAG"
ADDON_JFFS_ADN_DIR="/jffs/addons/$ADDON_TAG"
ADDON_LOGS_DIR="$ADDON_SHARE_DIR/logs"
ADDON_TMP_DIR="$ADDON_SHARE_DIR/tmp"
ADDON_LOCKFILE="/tmp/$ADDON_TAG.lock"

SS_CONF_FILE="/opt/etc/$ADDON_TAG.conf"
SS_API_BASE="https://api.stealthsurf.net"
SS_CACHE_CONFIGS="$ADDON_SHARE_DIR/configs.json"
SS_CACHE_LOCATIONS="$ADDON_SHARE_DIR/locations.json"
SS_CACHE_PROFILE="$ADDON_SHARE_DIR/profile.json"
SS_STATE_FILE="$ADDON_SHARE_DIR/state.json"
SS_UI_RESPONSE="$ADDON_WEB_DIR/stealthsurf-response.json"

XRAY_BIN="/opt/sbin/xray"
[ -x "$XRAY_BIN" ] || XRAY_BIN="/opt/bin/xray"
XRAY_CONFIG_FILE="/opt/etc/xray/stealthsurf.json"
XRAY_PIDFILE="/var/run/stealthsurf-xray.pid"

SS_API_KEY=""
SS_ACTIVE_CONFIG_ID=""
SS_SOCKS_PORT="10808"
SS_HTTP_PORT="10809"
SS_MODE="proxy" # proxy | redirect (redirect = basic transparent LAN)

if [ -f "$SS_CONF_FILE" ]; then
  # shellcheck disable=SC1090
  . "$SS_CONF_FILE"
fi
