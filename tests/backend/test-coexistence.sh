#!/bin/sh
# Coexistence guards: StealthSurf must not wipe stock XrayUI resources
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail=0
pass() { echo "OK  $1"; }
bad() {
  echo "FAIL $1"
  fail=$((fail + 1))
}

# --- cron_jobs_clear must only match stealthsurf ---
cron_src="$ROOT/src/backend/cron.sh"
sed -n '/^cron_jobs_clear()/,/^}/p' "$cron_src" >"$TMP/cron_clear_body.sh"
grep -q "grep -E '^stealthsurf'" "$TMP/cron_clear_body.sh" && pass "cron clears only stealthsurf" || bad "cron clears only stealthsurf"
if grep -E "grep -E '.*xrayui|xrayui\)" "$TMP/cron_clear_body.sh" >/dev/null; then
  bad "cron clear still greps xrayui jobs"
else
  pass "cron clear does not grep xrayui jobs"
fi

# Extract cron_jobs_clear and simulate cru
cat >"$TMP/cron_test.sh" <<'EOF'
cru() {
  case "$1" in
  l)
    cat <<'CRU'
0 * * * * /jffs/scripts/xrayui cron geodata #xrayui_geodataupdate#
*/5 * * * * /jffs/scripts/stealthsurf cron watchdog #stealthsurf_watchdog#
0 3 * * * /jffs/scripts/xrayui cron sub #xrayui_subscription_refresh#
CRU
    ;;
  d) echo "deleted:$2" >>"$TMP/deleted" ;;
  esac
}
log_info() { :; }
log_warn() { :; }
ADDON_TITLE=StealthSurf
EOF
# shellcheck disable=SC1091
. "$TMP/cron_test.sh"
# shellcheck disable=SC1091
sed -n '/^cron_jobs_clear()/,/^}/p' "$cron_src" >"$TMP/clear_fn.sh"
# shellcheck disable=SC1091
. "$TMP/clear_fn.sh"
: >"$TMP/deleted"
cron_jobs_clear
if grep -q 'xrayui' "$TMP/deleted" 2>/dev/null; then
  bad "cron deleted xrayui jobs"
else
  pass "cron left xrayui jobs alone"
fi
grep -q 'deleted:stealthsurf_watchdog' "$TMP/deleted" && pass "cron deleted stealthsurf job" || bad "cron deleted stealthsurf job"

# --- TUN isolation constants ---
tun_src="$ROOT/src/backend/tun.sh"
grep -q 'tun_table=251' "$tun_src" && pass "tun table 251" || bad "tun table 251"
grep -q 'tun_rule_priority_local=47' "$tun_src" && pass "tun local prio 47" || bad "tun local prio 47"
grep -q 'tun_rule_priority_tun=53' "$tun_src" && pass "tun tun prio 53" || bad "tun tun prio 53"
grep -q 'tun_default_ifname="ss0"' "$tun_src" && pass "tun default ss0" || bad "tun default ss0"
grep -q 'tun_configured_interface_names' "$tun_src" && pass "tun uses configured names" || bad "tun uses configured names"
# Must not enumerate all live xrayN on cleanup
if grep -A80 '^cleanup_tun_inbounds' "$tun_src" | grep -q "grep -E '^xray"; then
  bad "cleanup still enumerates live xrayN"
else
  pass "cleanup does not enumerate live xrayN"
fi
# Marker gate
grep -A20 '^cleanup_tun_inbounds' "$tun_src" | grep -q 'tun_routing_marker' && pass "cleanup gated on marker" || bad "cleanup gated on marker"

# --- dnsmasq strip ---
dns_src="$ROOT/src/backend/dnsmasq.sh"
grep -q '^dnsmasq_strip_addon_block()' "$dns_src" && pass "dnsmasq_strip exists" || bad "dnsmasq_strip exists"
# Simulate strip leaving #xrayui intact
ADDON_TAG=stealthsurf
log_debug() { :; }
# shellcheck disable=SC1091
sed -n '/^dnsmasq_strip_addon_block()/,/^}/p' "$dns_src" >"$TMP/strip_fn.sh"
# shellcheck disable=SC1091
. "$TMP/strip_fn.sh"
cat >"$TMP/dnsmasq.conf" <<'EOF'
# before
#xrayui start
no-resolv
server=127.0.0.1#5353
#xrayui end
#stealthsurf start
no-resolv
server=127.0.0.1#53000
#stealthsurf end
# after
EOF
dnsmasq_strip_addon_block "$TMP/dnsmasq.conf"
grep -q '#xrayui start' "$TMP/dnsmasq.conf" && pass "strip keeps xrayui block" || bad "strip keeps xrayui block"
grep -q '#stealthsurf start' "$TMP/dnsmasq.conf" && bad "strip removed stealthsurf" || pass "strip removed stealthsurf"

# --- uninstall never targets stock paths blindly ---
inst="$ROOT/src/backend/install.sh"
grep -q 'ss_xrayui_installed' "$inst" && pass "uninstall checks xrayui installed" || bad "uninstall checks xrayui installed"
grep 'rm -f' "$inst" | grep -q 'xrayui.conf' && bad "uninstall still rm xrayui.conf" || pass "uninstall does not rm xrayui.conf"
grep -q 'rm -rf /opt/etc/logrotate.d/xrayui\|rm -rf /opt/etc/logrotate.d/stealthsurf /opt/etc/logrotate.d/xrayui' "$inst" && bad "uninstall removes xrayui logrotate" || pass "uninstall skips xrayui logrotate"
grep -q 'rm -rf /opt/sbin/xrayui' "$inst" && bad "uninstall removes /opt/sbin/xrayui" || pass "uninstall skips /opt/sbin/xrayui"

# --- scribe path isolation ---
logs="$ROOT/src/backend/logs.sh"
grep -q 'SS_SCRIBE_CONF=' "$logs" && pass "scribe uses stealthsurf path" || bad "scribe uses stealthsurf path"
if grep -n 'cat >/opt/etc/syslog-ng.d/xrayui' "$logs" >/dev/null; then
  bad "scribe still writes stock xrayui path"
else
  pass "scribe does not write stock xrayui path"
fi

# --- ASD cleanup scoped ---
helper="$ROOT/src/backend/_helper.sh"
grep -A15 '^cleanup_stale_asdfiles' "$helper" | grep -q 'stealthsurf_\*_bk' && pass "asd cleans stealthsurf only" || bad "asd cleans stealthsurf only"
grep -A15 '^cleanup_stale_asdfiles' "$helper" | grep -q 'xrayui_\*_bk' && bad "asd still cleans xrayui" || pass "asd does not clean xrayui"

# --- kill helpers scoped ---
grep -q 'ss_kill_by_cmdline_path' "$helper" && pass "path kill helper exists" || bad "path kill helper exists"
grep -q 'killall "b4sni"' "$ROOT/src/backend/b4sni.sh" && bad "b4sni still killall" || pass "b4sni no killall"
grep -q 'killall rtls-scanner' "$ROOT/src/backend/rtls.sh" && bad "rtls still killall" || pass "rtls no killall"

# --- API / dokodemo ports isolated from stock defaults ---
grep -q '10185' "$ROOT/src/backend/api.sh" && pass "api listen 10185" || bad "api listen 10185"
grep -q '10186' "$ROOT/src/backend/api.sh" && pass "metrics 10186" || bad "metrics 10186"
grep -q '"port": 5699' "$ROOT/src/backend/config.sh" && pass "dokodemo 5699" || bad "dokodemo 5699"

# --- backup naming ---
grep -q 'stealthsurf-\${timestamp}' "$ROOT/src/backend/backup.sh" && pass "backup prefix stealthsurf" || bad "backup prefix stealthsurf"

if [ "$fail" -ne 0 ]; then
  echo "FAILED: $fail"
  exit 1
fi
echo "ALL PASS"
