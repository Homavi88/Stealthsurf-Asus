#!/bin/sh
# panel_live_json must expose vpn_server from stealthsurf-default outbound.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
PANEL="$ROOT/src/backend/panel.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

grep -q 'panel_vpn_server_from_config' "$PANEL" || fail "missing panel_vpn_server_from_config"
grep -q 'vpn_server' "$PANEL" || fail "live JSON missing vpn_server"
grep -q 'panel_lan_devices_publish' "$PANEL" || fail "missing panel_lan_devices_publish"
grep -q 'lan-devices' "$ROOT/src/backend/mount.sh" || fail "mount must publish lan-devices"
grep -q 'panel_traffic_lifetime_tick' "$PANEL" || fail "missing lifetime traffic accumulator"
grep -q 'statsOutboundUplink' "$ROOT/src/backend/api.sh" || fail "API config must enable outbound stats"
grep -q 'api_write_stats_config' "$ROOT/src/backend/api.sh" || fail "StatsService must be writable without connection check"
grep -q 'api_config_required() {' "$ROOT/src/backend/api.sh" || fail "missing api_config_required"
# api_config_required must always succeed (Home traffic needs StatsService)
awk '/^api_config_required\(\)/,/^}/' "$ROOT/src/backend/api.sh" | grep -q 'return 0' ||
  fail "api_config_required must always return 0 for Home traffic stats"
grep -q 'traffic-lifetime' "$ROOT/src/backend/mount.sh" || fail "mount must publish traffic-lifetime"
grep -q 'is_skip_tag\|is_skip:' "$PANEL" || fail "VPN traffic must count non-ss-* proxy outbounds"
grep -q 'XRAY_DESIRED_STATE_FILE\|ssurf_xray.desired' "$PANEL" || fail "live status should use desired-state fallback"
grep -q 'fw_up' "$PANEL" || fail "live status should expose fw_up"
# Fail-soft: never stick the UI on ok:false when traffic jq breaks
grep -q 'Never fail the whole status payload' "$PANEL" || fail "live JSON must have fail-soft fallback"

echo "ok: vpn_server + lan-devices + lifetime traffic + online status wiring"
