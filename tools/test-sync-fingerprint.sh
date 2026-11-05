#!/bin/sh
# Offline checks: provider sync fingerprint + change detection helpers.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export ADDON_TAG="stealthsurf"
export ADDON_VERSION=1.0.7
export ADDON_TMP_DIR="$TMP/tmp"
export ADDON_DATA_DIR="$TMP/data"
export ADDON_WEB_DIR="$TMP/web"
export ADDON_SHARE_DIR="$TMP"
export ADDON_LOGS_DIR="$TMP/logs"
export SS_CACHE_CONFIGS="$TMP/configs.json"
export SS_CACHE_LOCATIONS="$TMP/locations.json"
export SS_CACHE_SUBSCRIPTIONS="$TMP/subscriptions.json"
export SS_CACHE_KEYS="$TMP/api_keys.json"
export SS_CONF_FILE="$TMP/stealthsurf.conf"
export SS_STATE_FILE="$TMP/state.json"
export SS_API_BASE="https://api.stealthsurf.net"
export XRAY_CONFIG_FILE="$TMP/xray.json"
export SS_ENABLED_OUTBOUNDS="42"
export SS_ACTIVE_CONFIG_ID="42"
export SS_DEFAULT_OUTBOUND="ss-42"
mkdir -p "$ADDON_TMP_DIR" "$ADDON_DATA_DIR" "$ADDON_WEB_DIR" "$ADDON_LOGS_DIR"
: >"$SS_CONF_FILE"
echo '[]' >"$SS_CACHE_LOCATIONS"
echo '[]' >"$SS_CACHE_SUBSCRIPTIONS"
echo '[]' >"$SS_CACHE_KEYS"

ss_log() { :; }
ss_info() { :; }
ss_ok() { :; }
ss_warn() { :; }
ss_error() { echo "ERR: $*" >&2; }
ss_activity() { :; }
ss_ensure_dirs() { mkdir -p "$ADDON_DATA_DIR" "$ADDON_TMP_DIR"; }
ss_xray_running() { return 1; }
ss_desired_is_set() { return 1; }
ss_rebuild_and_restart() {
  echo "rebuild_called" >>"$TMP/rebuild.log"
  return 0
}
ss_all_api_keys() { echo ""; }

# Minimal stubs for unused api helpers pulled via file
ss_api() { return 1; }

# shellcheck disable=SC1091
. "$ROOT/src/backend/api_client.sh"

fail=0
assert_eq() {
  local name="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    echo "OK  $name"
  else
    echo "FAIL $name got='$got' want='$want'"
    fail=$((fail + 1))
  fi
}

cat >"$SS_CACHE_CONFIGS" <<'EOF'
[
  {
    "id": 42,
    "protocol": "vless",
    "location_id": 3,
    "server_id": 9,
    "title": "NL",
    "is_online": true,
    "connection_url": "vless://u@host:443?type=tcp&security=reality#a",
    "xray_config": "{\"use_xhttp\":false}",
    "awg_config": null
  },
  {
    "id": 99,
    "protocol": "trojan",
    "location_id": 1,
    "server_id": 2,
    "title": "other",
    "is_online": true,
    "connection_url": "trojan://x@y:443",
    "xray_config": null,
    "awg_config": null
  }
]
EOF

fp1=$(ss_enabled_configs_fingerprint)
[ -n "$fp1" ] && [ "$fp1" != "none" ] && echo "OK  fingerprint non-empty" || {
  echo "FAIL fingerprint empty"
  fail=$((fail + 1))
}

# Change only disabled config → fingerprint for enabled must stay same
jq 'map(if .id==99 then .connection_url="trojan://changed" else . end)' "$SS_CACHE_CONFIGS" >"$TMP/c2.json"
mv "$TMP/c2.json" "$SS_CACHE_CONFIGS"
fp2=$(ss_enabled_configs_fingerprint)
assert_eq "ignore disabled config changes" "$fp2" "$fp1"

# Change enabled connection_url → fingerprint must change
jq 'map(if .id==42 then .connection_url="vless://u@host:443?type=xhttp&security=reality#b" else . end)' "$SS_CACHE_CONFIGS" >"$TMP/c3.json"
mv "$TMP/c3.json" "$SS_CACHE_CONFIGS"
fp3=$(ss_enabled_configs_fingerprint)
if [ "$fp3" != "$fp1" ]; then
  echo "OK  enabled URL change updates fingerprint"
else
  echo "FAIL fingerprint did not change after URL update"
  fail=$((fail + 1))
fi

# apply_provider_changes: no xray/config → cache note, write fingerprint, no rebuild
rm -f "$TMP/rebuild.log" "$ADDON_DATA_DIR/enabled-configs.fp"
ss_apply_provider_changes >/dev/null
[ -f "$ADDON_DATA_DIR/enabled-configs.fp" ] && echo "OK  fingerprint file written" || {
  echo "FAIL no fingerprint file"
  fail=$((fail + 1))
}
[ ! -f "$TMP/rebuild.log" ] && echo "OK  no rebuild when dataplane absent" || {
  echo "FAIL unexpected rebuild"
  fail=$((fail + 1))
}

# Second apply with same cache → unchanged path
ss_apply_provider_changes >/dev/null
[ ! -f "$TMP/rebuild.log" ] && echo "OK  unchanged skip" || {
  echo "FAIL rebuild on unchanged"
  fail=$((fail + 1))
}

# Simulate running dataplane + URL change → rebuild
: >"$XRAY_CONFIG_FILE"
ss_xray_running() { return 0; }
jq 'map(if .id==42 then .protocol="trojan" else . end)' "$SS_CACHE_CONFIGS" >"$TMP/c4.json"
mv "$TMP/c4.json" "$SS_CACHE_CONFIGS"
ss_apply_provider_changes >/dev/null
grep -q rebuild_called "$TMP/rebuild.log" && echo "OK  rebuild on provider change" || {
  echo "FAIL expected rebuild"
  fail=$((fail + 1))
}

if [ "$fail" -ne 0 ]; then
  echo "FAILED: $fail"
  exit 1
fi
echo "All sync fingerprint tests passed"
