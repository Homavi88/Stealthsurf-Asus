#!/bin/sh
# shellcheck disable=SC2034  # codacy:Unused variables

export PATH="/opt/bin:/opt/sbin:/sbin:/bin:/usr/sbin:/usr/bin"
export LC_ALL=C
unset LD_LIBRARY_PATH

source /usr/sbin/helper.sh

# Runtime tag is ssurf — NEVER share paths with official StealthSurf
# (/jffs/addons/stealthsurf + stealthsurf-routerd :8800).
ADDON_TAG="ssurf"
ADDON_TAG_UPPER="SSURF"
ADDON_TITLE="SurfGate"
# Merlin/UI action_script prefix (Homavi88 panel protocol). Not the official addon.
ADDON_ACTION_PREFIX="stealthsurf"

XRAYUI_VERSION="1.4.42"
# Xray-core version fresh installs get: the one this release was tested with.
XRAYUI_TESTED_CORE="26.9.9"

ADDON_WEB_DIR="/www/user/$ADDON_TAG"

ADDON_SCRIPT="/jffs/scripts/$ADDON_TAG"
ADDON_SHARE_DIR="/opt/share/$ADDON_TAG"
# Package files live under /jffs/addons/ssurf — NEVER /jffs/addons/stealthsurf
ADDON_PKG_NAME="ssurf"
ADDON_JFFS_ADN_DIR="/jffs/addons/$ADDON_PKG_NAME"
# Official router app path — we never install into, delete, or call it.
OFFICIAL_SS_JFFS_DIR="/jffs/addons/stealthsurf"
OFFICIAL_SS_DAEMON="$OFFICIAL_SS_JFFS_DIR/sbin/stealthsurf-routerd"
ADDON_USER_SCRIPTS_DIR="/jffs/${ADDON_TAG}_custom"
ADDON_LOGS_DIR="$ADDON_SHARE_DIR/logs"
ADDON_TMP_DIR="$ADDON_SHARE_DIR/tmp"

# Standalone SurfGate panel on :1131 (official app uses :8800 separately)
PANEL_DEFAULT_PORT=1131
PANEL_WEB_ROOT="$ADDON_JFFS_ADN_DIR/panel"
PANEL_PIDFILE=/var/run/ssurf-panel.pid

ADDON_DEBUG="false"

XRAYUI_LOCKFILE=/tmp/$ADDON_TAG.lock

UI_RESPONSE_FILE="$ADDON_WEB_DIR/xray-ui-response.json"

XRAYUI_CLIENTS_FILE="$ADDON_SHARE_DIR/xray_clients_online.json"
DEVICES_VPN_JSON="$ADDON_SHARE_DIR/devices_vpn.json"
DEVICES_VPN_LOG="$ADDON_LOGS_DIR/devices_vpn.log"
XRAYUI_CONNECTION_STATUS_FILE="$ADDON_SHARE_DIR/xray_connection_status.json"
XRAYUI_SUBSCRIPTIONS_FILE="$ADDON_SHARE_DIR/xray_subscriptions.json"
XRAYUI_GEOTAGS_FILE="$ADDON_SHARE_DIR/geodata_tags.json"
XRAYUI_FAILOVER_STATE_FILE="$ADDON_SHARE_DIR/xray_failover_state.json"

# Isolated from stock XrayUI (/opt/etc/xray/config.json) and from official StealthSurf
XRAY_CONFIG_DIR="/opt/etc/xray/$ADDON_TAG"
DEFAULT_XRAY_PROFILE_NAME="config.json"
DEFAULT_GEOIP_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
DEFAULT_GEOSITE_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
# Fallback when Loyalsoldier GitHub releases are unreachable (RU/blocked regions)
FALLBACK_GEOIP_URL="https://raw.githubusercontent.com/runetfreedom/russia-v2ray-rules-dat/release/geoip.dat"
FALLBACK_GEOSITE_URL="https://raw.githubusercontent.com/runetfreedom/russia-v2ray-rules-dat/release/geosite.dat"
# Reject truncated / HTML error pages
GEODATA_MIN_BYTES=102400
CUSTOM_GEODATA_NAME="$ADDON_TAG"

XRAYUI_CONFIG_FILE="/opt/etc/$ADDON_TAG.conf"

# StealthSurf *provider* API (control plane) — not the official router addon
SS_API_BASE="https://api.stealthsurf.net"
SS_API_KEY=""
SS_API_KEYS=""
SS_CACHE_KEYS="$ADDON_SHARE_DIR/api_keys.json"
SS_CACHE_BALANCES="$ADDON_SHARE_DIR/balances.json"
SS_CACHE_CONFIGS="$ADDON_SHARE_DIR/ss_configs.json"
SS_CACHE_LOCATIONS="$ADDON_SHARE_DIR/ss_locations.json"
SS_CACHE_PROFILE="$ADDON_SHARE_DIR/ss_profile.json"
SS_CACHE_SUBSCRIPTIONS="$ADDON_SHARE_DIR/ss_subscriptions.json"
SS_CACHE_PAID="$ADDON_SHARE_DIR/ss_paid_options.json"
SS_CACHE_CLOUD="$ADDON_SHARE_DIR/ss_cloud_servers.json"
SS_CACHE_TARIFFS="$ADDON_SHARE_DIR/ss_tariffs.json"
SS_CACHE_TRAFFIC="$ADDON_SHARE_DIR/ss_traffic.json"
SS_CACHE_SERVER_STATS="$ADDON_SHARE_DIR/ss_server_stats.json"
SS_CACHE_AVAILABLE_SERVERS="$ADDON_SHARE_DIR/ss_available_servers.json"
SS_CACHE_AUTOFIT="$ADDON_SHARE_DIR/ss_autofit.json"
SS_IMPORTED_FP_FILE="$ADDON_SHARE_DIR/imported-configs.fp"
SS_LAST_SYNC=""
# disabled | 15m | 30m | 1h | 3h | 6h | 12h
ss_catalog_auto_sync="disabled"
# Addon package update check against GitHub releases (Homavi88/Stealthsurf-Asus)
# disabled | 1h | 6h | 12h | 24h | 3d | 7d
addon_update_check="disabled"
# When true and a newer release is found by cron — install automatically
addon_auto_update="false"
# Kill-switch: block LAN→WAN while VPN is desired but traffic is unmarked
kill_switch="false"
# all | selected | exclude — simple device VPN mode (syncs routing.policies)
lan_vpn_mode="all"
lan_vpn_macs=""
# proxy | block | ignore
ipv6_mode="proxy"
# follow | vpn | direct — guest Wi-Fi bridges
guest_vpn_mode="follow"
# Comma-separated domains / geosite: tags that bypass VPN (→ direct)
split_bypass_domains=""
# true → .ru / .su / .рф (xn--p1ai) go direct
split_bypass_ru_tlds="false"
# true → curated RU services whitelist (gosuslugi, banks, VK/OK/Yandex, …) → direct
split_bypass_ru_services="false"
# Comma-separated domains that must stay on VPN (fail-closed if VPN/addon down)
split_lock_domains=""
# disabled | 6h | 12h | 24h — optional cron speed test
speedtest_interval="disabled"
PREFLIGHT_STATUS_FILE="$ADDON_SHARE_DIR/preflight_status.json"
SPEEDTEST_STATUS_FILE="$ADDON_SHARE_DIR/speedtest_status.json"
DNSTEST_STATUS_FILE="$ADDON_SHARE_DIR/dnstest_status.json"
ADDON_UPDATE_STATUS_FILE="$ADDON_SHARE_DIR/addon_update_status.json"
# Cumulative traffic (survives Xray restart / reboot)
TRAFFIC_LIFETIME_FILE="$ADDON_SHARE_DIR/traffic_lifetime.json"
TRAFFIC_SNAPSHOT_FILE="$ADDON_TMP_DIR/traffic_snapshot.json"
ADDON_APP_LOG="$ADDON_LOGS_DIR/ssurf_app.log"
DEVICES_VPN_HISTORY_LOG="$ADDON_LOGS_DIR/devices_vpn_history.log"
ADDON_CHANNEL="beta"
ADDON_REPO="Homavi88/Stealthsurf-Asus"

XRAY_VERSION="0.0"
XRAYUI_CORE_VER_CACHE=""
XRAYUI_CORE_ERR=""
# Own pidfile — never share /var/run/xray.pid with stock XrayUI
XRAY_PIDFILE=/var/run/ssurf-xray.pid
XRAY_RESTART_LOCKFILE=/tmp/$ADDON_TAG.restart.lock
XRAY_RESTART_LOCK_FD=387
XRAY_CONFIG_FILE="$XRAY_CONFIG_DIR/${profile:-$DEFAULT_XRAY_PROFILE_NAME}"

POST_RESTART_DNSMASQ="false"
FIREWALL_FROM_HOOK="false"

# Firewall — MUST differ from stock XrayUI (XRAYUI/0x10000/77) and official StealthSurf
FW_CHAIN="$ADDON_TAG_UPPER"
FW_DNS_LOCK_CHAIN="${ADDON_TAG_UPPER}_DNS_LOCK"
FW_DNS_OWNERPROBE_CHAIN="${ADDON_TAG_UPPER}_DNS_OWNERPROBE"
FW_DIVERT_CHAIN="${ADDON_TAG_UPPER}_DIVERT"
tproxy_mark=0x20000
tproxy_mask=0x20000
tproxy_table=78
XRAYUI_FIREWALL_LOCKFILE=/tmp/$ADDON_TAG.firewall.lock

IPSET_BYPASS_V4="${ADDON_TAG_UPPER}_BYPASS4"
IPSET_BYPASS_V6="${ADDON_TAG_UPPER}_BYPASS6"
IPSET_PROXY_V4="${ADDON_TAG_UPPER}_PROXY4"
IPSET_PROXY_V6="${ADDON_TAG_UPPER}_PROXY6"
IPSET_BYPASS_NET_V4="${ADDON_TAG_UPPER}_BYPASS4_NET"
IPSET_BYPASS_NET_V6="${ADDON_TAG_UPPER}_BYPASS6_NET"
IPSET_PROXY_NET_V4="${ADDON_TAG_UPPER}_PROXY4_NET"
IPSET_PROXY_NET_V6="${ADDON_TAG_UPPER}_PROXY6_NET"
IPSET_LOCK_V4="${ADDON_TAG_UPPER}_LOCK4"
IPSET_LOCK_V6="${ADDON_TAG_UPPER}_LOCK6"
IPSET_LEARNED_FILE="$ADDON_SHARE_DIR/dnsmasq/learned.ipset"
FW_SVCLOCK_CHAIN="${ADDON_TAG_UPPER}_SVCLOCK"

IONICE=""
NICE=""
ionice -c3 true >/dev/null 2>&1 && IONICE="ionice -c3"
nice -n 19 true >/dev/null 2>&1 && NICE="nice -n 19"

if [ -f "$XRAYUI_CONFIG_FILE" ]; then
    . "$XRAYUI_CONFIG_FILE"
elif [ -f /opt/etc/stealthsurf.conf ]; then
    # One-time read of pre-1.4.11 Homavi88 conf (not official addon files)
    . /opt/etc/stealthsurf.conf
fi
