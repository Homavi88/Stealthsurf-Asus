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
grep -q 'traffic-lifetime' "$ROOT/src/backend/mount.sh" || fail "mount must publish traffic-lifetime"

echo "ok: vpn_server + lan-devices + lifetime traffic wiring"
