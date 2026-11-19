#!/bin/sh
# Unit tests for official StealthSurf conflict detection helpers
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass() { echo "OK  $*"; }
bad() { echo "FAIL  $*" >&2; exit 1; }

export OFFICIAL_SS_JFFS_DIR="$TMP/official"
export OFFICIAL_SS_DAEMON="$OFFICIAL_SS_JFFS_DIR/sbin/stealthsurf-routerd"
export SS_OFFICIAL_CACHE="$TMP/official.cache"
export SS_OFFICIAL_CACHE_TTL=60

# Quiet stubs
log_error() { echo "ERR: $*" >&2; }
log_warn() { :; }
log_info() { :; }
watchdog_clear_desired() { :; }
ss_refuse_if_xrayui() { return 0; }
ss_xrayui_running() { return 1; }
ss_xrayui_conflict_message() { printf '%s\n' "xrayui"; }

# shellcheck disable=SC1091
. "$ROOT/src/backend/official_conflict.sh"

ss_official_process_running() { return 1; }
ss_official_firewall_active() { return 1; }

rm -rf "$OFFICIAL_SS_JFFS_DIR"
ss_official_cache_invalidate

ss_official_installed && bad "idle should not be installed" || pass "not installed"
ss_official_running && bad "idle should not run" || pass "idle not running"

mkdir -p "$OFFICIAL_SS_JFFS_DIR/sbin"
printf '#!/bin/sh\nexit 0\n' >"$OFFICIAL_SS_DAEMON"
chmod +x "$OFFICIAL_SS_DAEMON"
ss_official_installed && pass "installed via daemon path" || bad "installed via daemon path"

ss_official_cache_invalidate
ss_official_running && bad "installed but idle" || pass "installed but idle"

# Simulate running process
ss_official_process_running() { return 0; }
ss_official_cache_invalidate
ss_official_running && pass "running via process" || bad "running via process"

json=$(ss_official_status_json)
echo "$json" | jq -e '.running==true and .conflict=="official"' >/dev/null \
  && pass "status json conflict" || bad "status json conflict: $json"

if ss_refuse_if_official; then
  bad "refuse should fail while running"
else
  pass "refuse while running"
fi

ss_official_process_running() { return 1; }
ss_official_cache_invalidate
if ss_refuse_if_official; then
  pass "refuse allows idle"
else
  bad "refuse allows idle"
fi

# Combined guard
ss_official_process_running() { return 0; }
ss_official_cache_invalidate
if ss_refuse_if_dataplane_conflict; then
  bad "dataplane refuse should fail"
else
  pass "dataplane refuse while official running"
fi

ss_official_process_running() { return 1; }
ss_official_cache_invalidate
ss_official_cache_store 1
ss_official_running && pass "cache hit running" || bad "cache hit running"
ss_official_running force && bad "force ignores stale cache" || pass "force ignores stale cache"

echo "ALL PASS"
