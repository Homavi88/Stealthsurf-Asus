#!/bin/sh
# ensure_xray_scaffold must strip top-level legacy reverse (Xray ≥26.9)
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass() { echo "OK  $*"; }
bad() { echo "FAIL  $*" >&2; exit 1; }

export XRAYUI_CONFIG_FILE="$TMP/ssurf.conf"
export XRAY_CONFIG_DIR="$TMP/xray"
export ADDON_LOGS_DIR="$TMP/logs"
export ADDON_WEB_DIR="$TMP/www"
export ADDON_SHARE_DIR="$TMP/share"
export DEFAULT_XRAY_PROFILE_NAME=config.json
export profile=config.json
mkdir -p "$XRAY_CONFIG_DIR" "$ADDON_LOGS_DIR" "$ADDON_WEB_DIR" "$ADDON_SHARE_DIR"
: >"$XRAYUI_CONFIG_FILE"

# Minimal stubs used by config.sh
update_xrayui_config() { :; }
log_warn() { :; }
log_ok() { :; }
log_error() { echo "$*" >&2; }
log_info() { :; }

# shellcheck disable=SC1091
. "$ROOT/src/backend/config.sh"

cat >"$XRAY_CONFIG_DIR/config.json" <<'EOF'
{
  "inbounds": [],
  "outbounds": [],
  "routing": { "rules": [] },
  "reverse": {
    "bridges": [{ "tag": "bridge", "domain": "reverse.internal" }],
    "portals": [{ "tag": "portal", "domain": "reverse.internal" }]
  }
}
EOF

ensure_xray_scaffold

jq -e 'has("reverse") | not' "$XRAY_CONFIG_DIR/config.json" >/dev/null \
  && pass "legacy reverse stripped" || bad "legacy reverse still present: $(jq -c '.reverse' "$XRAY_CONFIG_DIR/config.json")"

jq -e '[.inbounds[] | select(.tag=="all-in")] | length > 0' "$XRAY_CONFIG_DIR/config.json" >/dev/null \
  && pass "all-in scaffold kept" || bad "all-in missing"

jq -e '[.outbounds[] | select(.tag=="direct")] | length > 0' "$XRAY_CONFIG_DIR/config.json" >/dev/null \
  && pass "direct outbound kept" || bad "direct missing"

echo "ALL PASS"
