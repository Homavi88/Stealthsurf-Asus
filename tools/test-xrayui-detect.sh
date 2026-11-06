#!/bin/sh
# Unit tests for XrayUI conflict detection helpers
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export ADDON_TAG=stealthsurf
export ADDON_LOGS_DIR="$TMP/logs"
export XRAY_PIDFILE="$TMP/stealthsurf-xray.pid"
export SS_XRAYUI_PIDFILE="$TMP/xray.pid"
export SS_XRAYUI_DESIRED="$TMP/xrayui.desired"
export SS_XRAYUI_CONFIG="$TMP/config.json"
export SS_XRAYUI_CACHE="$TMP/xrayui.cache"
export SS_XRAYUI_CACHE_TTL=60
mkdir -p "$ADDON_LOGS_DIR"

# shellcheck disable=SC1091
. "$ROOT/src/backend/_helper.sh"

# Quiet stubs after source (overwrite logger helpers)
ss_log() { :; }
ss_ok() { :; }
ss_info() { :; }
ss_warn() { :; }
ss_error() { :; }
ss_activity() { :; }
ss_desired_clear() { rm -f "$TMP/stealthsurf.desired"; }
ss_resolve_system_iptables() { printf '%s\n' "false"; }
ss_xrayui_installed() { return 1; } # isolate from host filesystem
ss_xrayui_process_running() { return 1; }
ss_xrayui_firewall_active() { return 1; }

fail=0
pass() { echo "OK  $1"; }
bad() {
  echo "FAIL $1"
  fail=$((fail + 1))
}

rm -f "$SS_XRAYUI_PIDFILE" "$XRAY_PIDFILE" "$SS_XRAYUI_DESIRED"
ss_xrayui_cache_invalidate

ss_xrayui_running && bad "idle should not run" || pass "idle not running"
ss_xrayui_pid_alive && bad "no pidfile" || pass "no pidfile"

echo $$ >"$SS_XRAYUI_PIDFILE"
ss_xrayui_cache_invalidate
ss_xrayui_pid_alive && pass "foreign pid alive" || bad "foreign pid alive"
ss_xrayui_running && pass "running via pid" || bad "running via pid"

# Our own pid must not count as xrayui
cp "$SS_XRAYUI_PIDFILE" "$XRAY_PIDFILE"
ss_xrayui_pid_alive && bad "ours must not be xrayui pid" || pass "ours excluded from xrayui pid"

rm -f "$XRAY_PIDFILE"
echo 999999 >"$SS_XRAYUI_PIDFILE"
ss_xrayui_pid_alive && bad "dead pid" || pass "dead pid ignored"
rm -f "$SS_XRAYUI_PIDFILE"
ss_xrayui_cache_invalidate

json=$(ss_xrayui_status_json)
echo "$json" | jq -e 'has("installed") and has("running") and (.conflict==null)' >/dev/null \
  && pass "status json idle" || bad "status json idle"

echo $$ >"$SS_XRAYUI_PIDFILE"
touch "$TMP/stealthsurf.desired"
if ss_refuse_if_xrayui; then
  bad "refuse should block"
else
  pass "refuse blocks"
fi
[ ! -f "$TMP/stealthsurf.desired" ] && pass "desired cleared" || bad "desired cleared"

json=$(ss_xrayui_status_json)
echo "$json" | jq -e '.running==true and .conflict=="xrayui"' >/dev/null \
  && pass "status json conflict" || bad "status json conflict"

rm -f "$SS_XRAYUI_PIDFILE"
if ss_refuse_if_xrayui; then
  pass "refuse allows when idle"
else
  bad "refuse allows when idle"
fi

# TTL cache: second call must not need pidfile if cache says idle
ss_xrayui_cache_invalidate
ss_xrayui_running && bad "cache idle baseline" || pass "cache idle baseline"
# Poison: if cache says running without pid, periodic path trusts TTL
ss_xrayui_cache_store 1
ss_xrayui_running && pass "cache hit running" || bad "cache hit running"
ss_xrayui_running force && bad "force ignores stale cache" || pass "force ignores stale cache"
ss_xrayui_cache_invalidate

# installed=false skips process scan on periodic path
ss_xrayui_installed() { return 1; }
ss_xrayui_process_running() {
  bad "process scan should be skipped when not installed"
  return 1
}
ss_xrayui_running && bad "not installed should be idle" || pass "skip process when not installed"

if [ "$fail" -ne 0 ]; then
  echo "FAILED: $fail"
  exit 1
fi
echo "ALL PASS"
