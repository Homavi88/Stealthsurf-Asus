#!/bin/sh
# Unit tests for VPN hardening helpers (no router required)
set -e
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export ADDON_TAG_UPPER=SSURF
export ADDON_SHARE_DIR="$TMP/share"
export ADDON_LOGS_DIR="$TMP/logs"
export ADDON_TMP_DIR="$TMP/tmp"
export ADDON_WEB_DIR="$TMP/www"
export XRAY_CONFIG_DIR="$TMP/xray"
export XRAY_CONFIG_FILE="$XRAY_CONFIG_DIR/config.json"
export XRAYUI_CONFIG_FILE="$TMP/ssurf.conf"
export XRAY_DESIRED_STATE_FILE="$TMP/desired"
export PREFLIGHT_STATUS_FILE="$ADDON_SHARE_DIR/preflight_status.json"
export tproxy_mark=0x20000
export tproxy_mask=0x20000
mkdir -p "$ADDON_SHARE_DIR" "$ADDON_LOGS_DIR" "$ADDON_TMP_DIR" "$ADDON_WEB_DIR" "$XRAY_CONFIG_DIR"

# stubs
log_info() { :; }
log_ok() { :; }
log_warn() { :; }
log_debug() { :; }
log_error() { :; }
load_xrayui_config() { :; }
update_xrayui_config() { :; }
get_xray_daemon_pid() { echo ""; }
ss_xrayui_running() { return 1; }
ss_official_running() { return 1; }
is_ipv6_enabled() { return 1; }
setup_script_file() { printf '%s\n' "$2" >>"$TMP/hooks.txt"; }
ntp_ready() { echo ntp_called >>"$TMP/ntp.txt"; }
nvram() {
  case "$*" in
  *ntp_ready*) echo 1 ;;
  *wan0_ipaddr*) echo 1.2.3.4 ;;
  *wan0_ifname*) echo eth0 ;;
  *wan1_ifname*) echo "" ;;
  *lan_ifname*) echo br0 ;;
  *lan1_ifname*) echo br1 ;;
  *) echo "" ;;
  esac
}

# shellcheck disable=SC1091
. "$ROOT/src/backend/vpn_hardening.sh"

# ── 1. NTP wrapper ──────────────────────────────────────────────────────────
skipwait=false
vpn_ntp_wait
test -f "$TMP/ntp.txt"
grep -q ntp_called "$TMP/ntp.txt"

# ── 4. LAN policies sync ────────────────────────────────────────────────────
cat >"$XRAY_CONFIG_FILE" <<'EOF'
{"inbounds":[],"outbounds":[{"tag":"direct","protocol":"freedom"}],"routing":{"rules":[],"policies":[{"name":"keep-me","mode":"bypass","enabled":true,"mac":["11:11:11:11:11:11"]}]}}
EOF

lan_vpn_mode=selected
lan_vpn_macs="AA:BB:CC:DD:EE:01, aa:bb:cc:dd:ee:02"
vpn_lan_policies_sync
test "$(jq -r '[.routing.policies[]|select(.name=="surfgate-lan-selected")]|length' "$XRAY_CONFIG_FILE")" = "1"
test "$(jq -r '.routing.policies[]|select(.name=="surfgate-lan-selected")|.mode' "$XRAY_CONFIG_FILE")" = "redirect"
test "$(jq -r '.routing.policies[]|select(.name=="surfgate-lan-selected")|.mac|length' "$XRAY_CONFIG_FILE")" = "2"
test "$(jq -r '[.routing.policies[]|select(.name=="keep-me")]|length' "$XRAY_CONFIG_FILE")" = "1"

lan_vpn_mode=exclude
lan_vpn_macs="aa:bb:cc:dd:ee:ff"
vpn_lan_policies_sync
test "$(jq -r '.routing.policies[]|select(.name=="surfgate-lan-exclude")|.mode' "$XRAY_CONFIG_FILE")" = "bypass"
test "$(jq -r '[.routing.policies[]|select(.name|startswith("surfgate-lan-selected"))]|length' "$XRAY_CONFIG_FILE")" = "0"

lan_vpn_mode=all
lan_vpn_macs=""
vpn_lan_policies_sync
test "$(jq -r '[.routing.policies[]|select(.name|startswith("surfgate-lan-"))]|length' "$XRAY_CONFIG_FILE")" = "0"
test "$(jq -r '[.routing.policies[]|select(.name=="keep-me")]|length' "$XRAY_CONFIG_FILE")" = "1"

# ── 8. Guest filter ─────────────────────────────────────────────────────────
guest_vpn_mode=direct
# Simulate guest net br1 = 192.168.2.0/24 in vpn_guest_nets_v4 via override
vpn_guest_nets_v4() { echo "192.168.2.0/24"; }
filtered=$(vpn_filter_source_nets "192.168.1.0/24 192.168.2.0/24 10.0.0.0/24")
echo "$filtered" | grep -q '192.168.1.0/24'
echo "$filtered" | grep -q '10.0.0.0/24'
! echo "$filtered" | grep -q '192.168.2.0/24'

guest_vpn_mode=follow
filtered2=$(vpn_filter_source_nets "192.168.1.0/24 192.168.2.0/24")
echo "$filtered2" | grep -q '192.168.2.0/24'

# guest=vpn unions guest nets even if missing from input list
guest_vpn_mode=vpn
filtered3=$(vpn_filter_source_nets "192.168.1.0/24")
echo "$filtered3" | grep -q '192.168.2.0/24'
vpn_guest_force_wanted
guest_force=$(vpn_guest_force_nets)
echo "$guest_force" | grep -q '192.168.2.0/24'

# ── Domain split bypass ─────────────────────────────────────────────────────
cat >"$XRAY_CONFIG_FILE" <<'EOF'
{"inbounds":[],"outbounds":[{"tag":"proxy","protocol":"vless"}],"routing":{"rules":[{"name":"keep","type":"field","outboundTag":"proxy"}]}}
EOF
split_bypass_domains="example.com, geosite:category-games"
split_bypass_ru_tlds=false
split_bypass_ru_services=false
vpn_split_rules_sync
test "$(jq -r '.routing.rules[0].name' "$XRAY_CONFIG_FILE")" = "surfgate-split-bypass"
test "$(jq -r '.routing.rules[0].outboundTag' "$XRAY_CONFIG_FILE")" = "direct"
test "$(jq -r '.outbounds[]|select(.tag=="direct")|.protocol' "$XRAY_CONFIG_FILE")" = "freedom"
jq -e '.routing.rules[0].domain | index("example.com")' "$XRAY_CONFIG_FILE" >/dev/null
jq -e '[.routing.rules[]|select(.name=="keep")]|length==1' "$XRAY_CONFIG_FILE" >/dev/null

# RU TLD preset
split_bypass_domains=""
split_bypass_ru_tlds=true
split_bypass_ru_services=false
vpn_split_rules_sync
jq -e '.routing.rules[0].domain | index("domain:ru")' "$XRAY_CONFIG_FILE" >/dev/null
jq -e '.routing.rules[0].domain | index("domain:su")' "$XRAY_CONFIG_FILE" >/dev/null
jq -e '.routing.rules[0].domain | index("domain:xn--p1ai")' "$XRAY_CONFIG_FILE" >/dev/null

# RU services preset (must not include geosite:geolocation-ru — absent in Loyalsoldier dat)
split_bypass_ru_tlds=false
split_bypass_ru_services=true
vpn_split_rules_sync
jq -e '.routing.rules[0].domain | index("gosuslugi.ru")' "$XRAY_CONFIG_FILE" >/dev/null
jq -e '.routing.rules[0].domain | index("vk.com")' "$XRAY_CONFIG_FILE" >/dev/null
jq -e '.routing.rules[0].domain | index("geosite:yandex")' "$XRAY_CONFIG_FILE" >/dev/null
jq -e '.routing.rules[0].domain | index("geosite:category-ru")' "$XRAY_CONFIG_FILE" >/dev/null
jq -e '.routing.rules[0].domain | index("geosite:geolocation-ru") | not' "$XRAY_CONFIG_FILE" >/dev/null
# also ensure the preset helper itself never emits the bad tag
case "$(vpn_split_ru_services_domains)" in
*geolocation-ru*) echo "FAIL: ru services preset still has geolocation-ru" >&2; exit 1 ;;
esac

split_bypass_domains=""
split_bypass_ru_tlds=false
split_bypass_ru_services=false
vpn_split_rules_sync
jq -e '[.routing.rules[]|select(.name=="surfgate-split-bypass")]|length==0' "$XRAY_CONFIG_FILE" >/dev/null

# ── VPN-only / fail-closed lock ─────────────────────────────────────────────
cat >"$XRAY_CONFIG_FILE" <<'EOF'
{"inbounds":[],"outbounds":[{"tag":"proxy","protocol":"vless"},{"tag":"direct","protocol":"freedom"}],"routing":{"rules":[{"name":"keep","type":"field","outboundTag":"proxy"}]}}
EOF
split_lock_domains="netflix.com, geosite:netflix"
vpn_lock_rules_sync
test "$(jq -r '.routing.rules[0].name' "$XRAY_CONFIG_FILE")" = "surfgate-vpn-lock"
test "$(jq -r '.routing.rules[0].outboundTag' "$XRAY_CONFIG_FILE")" = "proxy"
jq -e '.routing.rules[0].domain | index("netflix.com")' "$XRAY_CONFIG_FILE" >/dev/null
jq -e '[.routing.rules[]|select(.name=="keep")]|length==1' "$XRAY_CONFIG_FILE" >/dev/null

# lock wins over bypass when both applied (lock synced after bypass)
split_bypass_domains="netflix.com"
vpn_split_rules_sync
vpn_lock_rules_sync
test "$(jq -r '.routing.rules[0].name' "$XRAY_CONFIG_FILE")" = "surfgate-vpn-lock"
test "$(jq -r '.routing.rules[1].name' "$XRAY_CONFIG_FILE")" = "surfgate-split-bypass"

split_lock_domains=""
vpn_lock_rules_sync
jq -e '[.routing.rules[]|select(.name=="surfgate-vpn-lock")]|length==0' "$XRAY_CONFIG_FILE" >/dev/null

# vpn_lock_wanted
split_lock_domains="example.com"
vpn_lock_wanted
split_lock_domains=""
! vpn_lock_wanted
split_lock_domains="  ,  "
! vpn_lock_wanted

# ── 6. Preflight JSON ───────────────────────────────────────────────────────
cat >"$XRAY_CONFIG_FILE" <<'EOF'
{"inbounds":[{"protocol":"dokodemo-door","tag":"all-in","port":5699}],"outbounds":[],"routing":{"rules":[]}}
EOF
vpn_preflight_run || true
test -f "$PREFLIGHT_STATUS_FILE"
jq -e '.checks.ntp == true' "$PREFLIGHT_STATUS_FILE" >/dev/null
jq -e '.checks.wan == true' "$PREFLIGHT_STATUS_FILE" >/dev/null
jq -e '.checks.dokodemo == true' "$PREFLIGHT_STATUS_FILE" >/dev/null
jq -e '.checks.xrayui_conflict == false' "$PREFLIGHT_STATUS_FILE" >/dev/null

# ── 2. WAN hook install ─────────────────────────────────────────────────────
: >"$TMP/hooks.txt"
vpn_wan_hook_install
grep -q 'wan-event' "$TMP/hooks.txt" || grep -q 'service_event wan reconnect' "$TMP/hooks.txt"
grep -q 'wan reconnect' "$TMP/hooks.txt"

# ── 7. IPv6 mode active ─────────────────────────────────────────────────────
ipv6_mode=ignore
! vpn_ipv6_mode_active

ipv6_mode=proxy
# Without real ipv6 stack this returns false — still callable
vpn_ipv6_mode_active || true

# ── version / kill-switch clear is a no-op without iptables chains ──────────
vpn_kill_switch_clear
vpn_ipv6_block_clear

echo "vpn_hardening.spec.sh: OK"
