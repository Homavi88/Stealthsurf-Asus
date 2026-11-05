#!/bin/sh
# shellcheck disable=SC2034

export PATH="/opt/bin:/opt/sbin:/sbin:/bin:/usr/sbin:/usr/bin"
export LC_ALL=C
unset LD_LIBRARY_PATH

ADDON_TAG="stealthsurf"
ADDON_TAG_UPPER="STEALTHSURF"
ADDON_TITLE="StealthSurf"
ADDON_VERSION="1.0.2"
SS_BACKUP_KEEP="10"
SS_AUTO_BACKUP="1"
SS_LOG_MAX_BYTES="1048576"

ADDON_WEB_DIR="/www/user/$ADDON_TAG"
ADDON_SCRIPT="/jffs/scripts/$ADDON_TAG"
ADDON_SHARE_DIR="/opt/share/$ADDON_TAG"
ADDON_JFFS_ADN_DIR="/jffs/addons/$ADDON_TAG"
ADDON_LOGS_DIR="$ADDON_SHARE_DIR/logs"
ADDON_TMP_DIR="$ADDON_SHARE_DIR/tmp"
ADDON_LOCKFILE="/tmp/$ADDON_TAG.lock"
ADDON_DATA_DIR="$ADDON_SHARE_DIR/data"
ADDON_BACKUP_DIR="$ADDON_SHARE_DIR/backups"

SS_CONF_FILE="/opt/etc/$ADDON_TAG.conf"
SS_API_BASE="https://api.stealthsurf.net"
SS_CACHE_CONFIGS="$ADDON_SHARE_DIR/configs.json"
SS_CACHE_LOCATIONS="$ADDON_SHARE_DIR/locations.json"
SS_CACHE_PROFILE="$ADDON_SHARE_DIR/profile.json"
SS_CACHE_SUBSCRIPTIONS="$ADDON_SHARE_DIR/subscriptions.json"
SS_CACHE_KEYS="$ADDON_SHARE_DIR/api_keys.json"
SS_STATE_FILE="$ADDON_SHARE_DIR/state.json"
SS_UI_RESPONSE="$ADDON_WEB_DIR/stealthsurf-response.json"
SS_POLICIES_FILE="$ADDON_SHARE_DIR/policies.json"
SS_ROUTING_FILE="$ADDON_SHARE_DIR/routing.json"
SS_OUTBOUNDS_FILE="$ADDON_SHARE_DIR/outbounds.json"
SS_ENDPOINTS_FILE="$ADDON_SHARE_DIR/endpoints.json"
SS_DIAG_FILE="$ADDON_SHARE_DIR/diag.json"

XRAY_BIN="/opt/sbin/xray"
[ -x "$XRAY_BIN" ] || XRAY_BIN="/opt/bin/xray"
XRAY_CONFIG_FILE="/opt/etc/xray/stealthsurf.json"
XRAY_PIDFILE="/var/run/stealthsurf-xray.pid"
XRAY_ACCESS_LOG="$ADDON_LOGS_DIR/xray-access.log"
XRAY_ERROR_LOG="$ADDON_LOGS_DIR/xray-error.log"
GEOIP_DAT="/opt/sbin/geoip.dat"
GEOSITE_DAT="/opt/sbin/geosite.dat"
HYSTERIA_BIN="/opt/sbin/hysteria"
[ -x "$HYSTERIA_BIN" ] || HYSTERIA_BIN="/opt/bin/hysteria"
WG_BIN="$(command -v wg 2>/dev/null || echo /usr/sbin/wg)"
AWG_BIN="$(command -v awg 2>/dev/null || echo /opt/bin/awg)"

SS_API_KEY=""
SS_API_KEYS="" # space-separated extra keys (legacy single + list)
SS_ACTIVE_CONFIG_ID=""
SS_DEFAULT_OUTBOUND="" # ss-<id> | direct | block
SS_ENABLED_OUTBOUNDS="" # space-separated config ids
SS_SOCKS_PORT="10808"
SS_HTTP_PORT="10809"
SS_TPROXY_PORT="10810"
SS_REDIRECT_PORT="10811"
SS_DNS_PORT="5353"
SS_MODE="proxy" # proxy | redirect | tproxy
SS_DNS_MODE="OFF" # OFF | BYPASS | REDIRECT
SS_PROXY_MODE="redirect" # redirect | tproxy — dataplane mode when SS_MODE!=proxy
SS_AUTO_START="1"
SS_WATCHDOG="1"
SS_FALLBACK_OUTBOUND="direct"

# Firewall / TPROXY marks
SS_TPROXY_MARK="0x10000"
SS_TPROXY_MASK="0x10000"
SS_TPROXY_TABLE="77"
SS_FW_CHAIN="STEALTHSURF"
SS_IPSET_PROXY_V4="ss_proxy_v4"
SS_IPSET_PROXY_V6="ss_proxy_v6"
SS_IPSET_BYPASS_V4="ss_bypass_v4"
SS_IPSET_BYPASS_V6="ss_bypass_v6"
SS_IPSET_LEARNED="$ADDON_SHARE_DIR/ipset_learned.save"

# Protocol support flags (runtime capability)
SS_PROTO_XRAY="vless vless-2410 trojan trojan-2901 shadowsocks-2022"
SS_PROTO_HY2="hysteria2"
SS_PROTO_WG="wg"
SS_PROTO_AWG="amnezia-wg-2"
SS_PROTO_OPENFLUX="openflux"
SS_PROTO_SUB="http socks5"

XRAY_RELEASE_API="https://api.github.com/repos/XTLS/Xray-core/releases/latest"
GEODATA_BASE="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download"
ADDON_REPO="Homavi88/Stealthsurf-Asus"
ADDON_RELEASE_TGZ="https://github.com/${ADDON_REPO}/releases/latest/download/asuswrt-merlin-stealthsurf.tar.gz"
ADDON_RELEASE_API="https://api.github.com/repos/${ADDON_REPO}/releases/latest"
SS_VERSION_FILE="$ADDON_SHARE_DIR/version.json"

if [ -f "$SS_CONF_FILE" ]; then
  # shellcheck disable=SC1090
  . "$SS_CONF_FILE"
fi
