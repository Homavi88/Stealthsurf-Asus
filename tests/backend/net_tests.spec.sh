#!/bin/sh
# Unit tests for speed / DNS leak helpers (no network)
set -e
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export ADDON_TAG_UPPER=SSURF
export ADDON_SHARE_DIR="$TMP/share"
export ADDON_WEB_DIR="$TMP/www"
export XRAY_CONFIG_FILE="$TMP/xray/config.json"
export XRAYUI_CONFIG_FILE="$TMP/ssurf.conf"
export SPEEDTEST_STATUS_FILE="$ADDON_SHARE_DIR/speedtest_status.json"
export DNSTEST_STATUS_FILE="$ADDON_SHARE_DIR/dnstest_status.json"
export xray_dns_only=false
mkdir -p "$ADDON_SHARE_DIR" "$ADDON_WEB_DIR" "$(dirname "$XRAY_CONFIG_FILE")"

log_info() { :; }
log_ok() { :; }
log_warn() { :; }
log_debug() { :; }
log_error() { :; }
load_xrayui_config() { :; }
update_loading_progress() { :; }
nvram() {
  case "$*" in
  *wan0_dns*) echo "8.8.8.8 1.2.3.4" ;;
  *wan_dns*) echo "" ;;
  *wan0_xdns*) echo "" ;;
  *) echo "" ;;
  esac
}

# shellcheck disable=SC1091
. "$ROOT/src/backend/net_tests.sh"

# ── Mbps helper ─────────────────────────────────────────────────────────────
test "$(net_tests_bps_to_mbps 1250000)" = "10.00"
test "$(net_tests_bps_to_mbps "")" = ""

# ── Speed test with mocked probes ───────────────────────────────────────────
speedtest_probe_latency_ms() { echo 42; }
speedtest_probe_download() { echo "2500000 5000000 2.000"; }
speedtest_probe_upload() { echo "1250000"; }

speedtest_run
test -f "$SPEEDTEST_STATUS_FILE"
jq -e '.ok == true' "$SPEEDTEST_STATUS_FILE" >/dev/null
jq -e '.download_mbps == 20' "$SPEEDTEST_STATUS_FILE" >/dev/null
jq -e '.upload_mbps == 10' "$SPEEDTEST_STATUS_FILE" >/dev/null
jq -e '.latency_ms == 42' "$SPEEDTEST_STATUS_FILE" >/dev/null
test -e "$ADDON_WEB_DIR/speedtest-status.json"

# Failed download
speedtest_probe_download() { echo ""; }
speedtest_probe_upload() { echo ""; }
speedtest_run || true
jq -e '.ok == false' "$SPEEDTEST_STATUS_FILE" >/dev/null

# ── DNS leak: wiring OK, no overlap ─────────────────────────────────────────
cat >"$XRAY_CONFIG_FILE" <<'EOF'
{
  "inbounds": [
    {"protocol":"dokodemo-door","listen":"127.0.0.1","port":1053,
     "settings":{"address":"1.1.1.1","port":53,"network":"tcp,udp","followRedirect":false}}
  ],
  "outbounds": [{"tag":"sys:dns-out","protocol":"freedom"}]
}
EOF
xray_dns_only=true
dnstest_has_firewall_lock() { return 0; }
dnstest_exit_ip() { echo "203.0.113.9"; }
dnstest_fetch_resolvers_json() {
  echo '[{"ip":"1.1.1.1","isp":"Cloudflare","country":"US"}]'
}

dnstest_run
jq -e '.ok == true' "$DNSTEST_STATUS_FILE" >/dev/null
jq -e '.leaked == false' "$DNSTEST_STATUS_FILE" >/dev/null
jq -e '.dns_only == true' "$DNSTEST_STATUS_FILE" >/dev/null
jq -e '.dns_wiring == true' "$DNSTEST_STATUS_FILE" >/dev/null
jq -e '.dokodemo_dns == true' "$DNSTEST_STATUS_FILE" >/dev/null
jq -e '.firewall_lock == true' "$DNSTEST_STATUS_FILE" >/dev/null
jq -e '.exit_ip == "203.0.113.9"' "$DNSTEST_STATUS_FILE" >/dev/null
test -e "$ADDON_WEB_DIR/dnstest-status.json"

# Overlap with WAN DNS → leak
dnstest_fetch_resolvers_json() {
  echo '[{"ip":"8.8.8.8","isp":"Google","country":"US"},{"ip":"9.9.9.9","isp":"Quad9","country":"US"}]'
}
dnstest_run || true
jq -e '.leaked == true' "$DNSTEST_STATUS_FILE" >/dev/null
jq -e '.ok == false' "$DNSTEST_STATUS_FILE" >/dev/null
jq -e '.overlap | contains("8.8.8.8")' "$DNSTEST_STATUS_FILE" >/dev/null

# dns_only without dokodemo
cat >"$XRAY_CONFIG_FILE" <<'EOF'
{"inbounds":[],"outbounds":[{"tag":"sys:dns-out","protocol":"freedom"}]}
EOF
dnstest_fetch_resolvers_json() { echo '[{"ip":"1.1.1.1","isp":"Cloudflare","country":"US"}]'; }
dnstest_run || true
jq -e '.ok == false' "$DNSTEST_STATUS_FILE" >/dev/null
jq -e '.dokodemo_dns == false' "$DNSTEST_STATUS_FILE" >/dev/null

echo "net_tests.spec.sh: OK"
