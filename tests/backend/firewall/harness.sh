#!/bin/sh
HARNESS_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_DIR=$(cd "$HARNESS_DIR/../../.." && pwd)
FW_STATE=$1
XRAY_CONFIG_FILE=$2
shift 2
FW_REAL_PATH=$PATH
LC_ALL=C
PATH="$HARNESS_DIR/bin:$PATH"
export FW_STATE FW_REAL_PATH PATH LC_ALL

for tool in iptables ip6tables ip ipset nvram modprobe lsmod logger nslookup ping jq date; do
    if [ "$(command -v "$tool")" != "$HARNESS_DIR/bin/$tool" ]; then
        echo "harness: $tool does not resolve to $HARNESS_DIR/bin/$tool; refusing to run" >&2
        exit 70
    fi
done

mkdir -p "$FW_STATE/tmp"
printf 'Name:\txray\nUid:\t%s\t%s\t%s\t%s\n' "${FW_XRAY_UID:-0}" "${FW_XRAY_UID:-0}" "${FW_XRAY_UID:-0}" "${FW_XRAY_UID:-0}" >"$FW_STATE/xray.status"
sed -e '/^import /d' \
    -e "s#/tmp/#$FW_STATE/tmp/#g" \
    -e "s#/proc/\"\$xray_pid\"/status#$FW_STATE/xray.status#g" \
    "${FW_SCRIPT:-$REPO_DIR/src/backend/firewall.sh}" >"$FW_STATE/firewall.$$.sh"

log_error() { printf 'ERROR: %s\n' "$*" >>"$FW_STATE/messages.log"; }
log_warn() { printf 'WARN: %s\n' "$*" >>"$FW_STATE/messages.log"; }
log_info() { :; }
log_ok() { :; }
log_debug() { :; }
update_loading_progress() { :; }
load_xrayui_config() { :; }
get_xray_daemon_pid() { echo 4242; }
configure_tun_inbounds() { :; }
cleanup_tun_inbounds() { :; }
kmod_load() { modprobe "$@"; }
kmod_is_loaded() { lsmod | grep -q "^$1 "; }

. "$FW_STATE/firewall.$$.sh"

is_ipv6_enabled() { [ "${FW_IPV6:-0}" = 1 ]; }
set_route_localnet() { printf 'set_route_localnet %s\n' "$1" >>"$FW_STATE/events.log"; }
dnsmasq_restart() { printf 'dnsmasq_restart\n' >>"$FW_STATE/events.log"; }
dnsmasq_has_xrayui_block() { [ "${FW_DNSMASQ_BLOCK:-1}" = 1 ]; }
dnsmasq_strip_addon_block() { printf 'dnsmasq_strip_addon_block\n' >>"$FW_STATE/events.log"; }

ADDON_USER_SCRIPTS_DIR="$FW_STATE/custom"
# Match production isolation from _globals.sh (never stock XrayUI marks/table/chains)
FW_CHAIN=STEALTHSURF
FW_DNS_LOCK_CHAIN=STEALTHSURF_DNS_LOCK
FW_DNS_OWNERPROBE_CHAIN=STEALTHSURF_DNS_OWNERPROBE
FW_DIVERT_CHAIN=STEALTHSURF_DIVERT
tproxy_mark=0x20000
tproxy_mask=0x20000
tproxy_table=78
IPSET_BYPASS_V4=STEALTHSURF_BYPASS4
IPSET_BYPASS_V6=STEALTHSURF_BYPASS6
IPSET_PROXY_V4=STEALTHSURF_PROXY4
IPSET_PROXY_V6=STEALTHSURF_PROXY6
IPSET_BYPASS_NET_V4=STEALTHSURF_BYPASS4_NET
IPSET_BYPASS_NET_V6=STEALTHSURF_BYPASS6_NET
IPSET_PROXY_NET_V4=STEALTHSURF_PROXY4_NET
IPSET_PROXY_NET_V6=STEALTHSURF_PROXY6_NET
IPSET_LEARNED_FILE="$FW_STATE/learned.ipset"
FIREWALL_FROM_HOOK=${FW_FROM_HOOK:-false}
POST_RESTART_DNSMASQ=${FW_POST_RESTART_DNSMASQ:-false}

if [ -n "${FW_PRESTATE:-}" ]; then
    eval "$FW_PRESTATE"
fi

for step do
    $step
done
