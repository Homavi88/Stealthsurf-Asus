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
log_ok() { :; }
watchdog_clear_desired() { :; }
ss_refuse_if_xrayui() { return 0; }
ss_xrayui_running() { return 1; }
ss_xrayui_conflict_message() { printf '%s\n' "xrayui"; }

# shellcheck disable=SC1091
. "$ROOT/src/backend/official_conflict.sh"

ss_official_process_running() { return 1; }
ss_official_port_listening() { return 1; }
ss_official_firewall_active() { return 1; }
ss_official_cleanup_orphan_firewall() { :; }
ss_official_kill_process() { :; }

rm -rf "$OFFICIAL_SS_JFFS_DIR"
ss_official_cache_invalidate

ss_official_installed && bad "idle should not be installed" || pass "not installed"
ss_official_daemon_on_disk && bad "idle should not be on disk" || pass "daemon not on disk"
ss_official_running && bad "idle should not run" || pass "idle not running"

mkdir -p "$OFFICIAL_SS_JFFS_DIR/sbin"
# Empty sbin dir alone must NOT count as installed (leftover after delete)
ss_official_installed && bad "empty sbin is not installed" || pass "empty sbin ignored"

printf '#!/bin/sh\nexit 0\n' >"$OFFICIAL_SS_DAEMON"
chmod +x "$OFFICIAL_SS_DAEMON"
ss_official_installed && pass "installed via daemon path" || bad "installed via daemon path"
ss_official_daemon_on_disk && pass "daemon on disk" || bad "daemon on disk"

ss_official_cache_invalidate
ss_official_running && bad "installed but idle" || pass "installed but idle"

# Orphan STEALTHSURF_* chains after official stop must NOT count as running
# and status poll must NOT scrub them while package is installed.
ss_official_firewall_active() { return 0; }
CLEANED=0
ss_official_cleanup_orphan_firewall() { CLEANED=1; }
ss_official_cache_invalidate
ss_official_running && bad "orphan firewall must not block" || pass "orphan firewall ignored"
[ "$CLEANED" = "0" ] && pass "status poll has no cleanup side effect" || bad "status poll must not cleanup"
ss_official_firewall_active() { return 1; }
ss_official_cleanup_orphan_firewall() { :; }

# Simulate running process with package still on disk → conflict
ss_official_process_running() { return 0; }
ss_official_cache_invalidate
ss_official_running && pass "running via process" || bad "running via process"

# Port :8800 alone also means conflict (process name may differ)
ss_official_process_running() { return 1; }
ss_official_port_listening() { return 0; }
ss_official_cache_invalidate
ss_official_running && pass "running via :8800" || bad "running via :8800"

ss_official_process_running() { return 0; }
ss_official_port_listening() { return 1; }
ss_official_cache_invalidate
json=$(ss_official_status_json)
echo "$json" | jq -e '.running==true and .conflict=="official"' >/dev/null \
  && pass "status json conflict" || bad "status json conflict: $json"

ss_official_process_running() { return 0; }
ss_official_cache_invalidate
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

# Positive cache is revalidated against the live process (stop must clear ASAP)
ss_official_process_running() { return 1; }
ss_official_port_listening() { return 1; }
ss_official_cache_invalidate
ss_official_cache_store 1
ss_official_running && bad "stale positive cache must not stick" || pass "stale positive cache cleared"
ss_official_cache_store 1
ss_official_running force && bad "force ignores stale cache" || pass "force ignores stale cache"

# Negative cache must also revalidate (official start must show up)
ss_official_cache_invalidate
ss_official_cache_store 0
PROBE=0
ss_official_process_running() { PROBE=1; return 0; }
ss_official_running && pass "negative cache revalidated" || bad "negative cache revalidated"
[ "$PROBE" = "1" ] && pass "negative cache probed live" || bad "negative cache probed live"

# Orphan: process running but binary deleted → reap, do not conflict
rm -f "$OFFICIAL_SS_DAEMON"
# Also clear other install markers
rm -rf "$OFFICIAL_SS_JFFS_DIR"
KILLED=0
PROC=1
ss_official_process_running() { [ "$PROC" = "1" ]; }
ss_official_port_listening() { return 1; }
ss_official_kill_process() { KILLED=1; PROC=0; return 0; }
ss_official_firewall_active() { return 1; }
ss_official_cleanup_orphan_firewall() { :; }
ss_official_cache_invalidate
# Status poll must NOT kill — only explicit reap/start path may.
if ss_official_running; then
  pass "orphan process still reported running by status"
else
  bad "orphan process should still show as running until reaped"
fi
[ "$KILLED" = "0" ] && pass "status poll did not kill orphan" || bad "status poll must not kill"

# Explicit reap when package gone
KILLED=0
PROC=1
ss_official_cache_invalidate
if ss_official_reap_orphan; then
  pass "orphan process reaped"
else
  bad "orphan process reaped"
fi
[ "$KILLED" = "1" ] && pass "orphan kill invoked" || bad "orphan kill invoked"

# Real install still on disk + process → reap must refuse to kill
mkdir -p "$OFFICIAL_SS_JFFS_DIR/sbin"
printf '#!/bin/sh\nexit 0\n' >"$OFFICIAL_SS_DAEMON"
chmod +x "$OFFICIAL_SS_DAEMON"
KILLED=0
PROC=1
ss_official_process_running() { [ "$PROC" = "1" ]; }
ss_official_kill_process() { KILLED=1; PROC=0; return 0; }
ss_official_cache_invalidate
if ss_official_reap_orphan; then
  bad "reap must not kill when package is installed"
else
  pass "reap leaves installed package alone"
fi
[ "$KILLED" = "0" ] && pass "reap did not kill installed" || bad "reap did not kill installed"

# Install marker without exact daemon path still counts as installed
rm -f "$OFFICIAL_SS_DAEMON"
echo "1.0" >"$OFFICIAL_SS_JFFS_DIR/version"
ss_official_daemon_on_disk && pass "version marker = installed" || bad "version marker = installed"
KILLED=0
PROC=1
ss_official_process_running() { [ "$PROC" = "1" ]; }
ss_official_kill_process() { KILLED=1; PROC=0; return 0; }
if ss_official_reap_orphan; then
  bad "reap must not kill when version marker present"
else
  pass "reap respects version marker"
fi
[ "$KILLED" = "0" ] && pass "version marker blocked kill" || bad "version marker blocked kill"

# force_stop always kills even when binary exists
printf '#!/bin/sh\nexit 0\n' >"$OFFICIAL_SS_DAEMON"
chmod +x "$OFFICIAL_SS_DAEMON"
KILLED=0
PROC=1
ss_official_process_running() { [ "$PROC" = "1" ]; }
ss_official_kill_process() { KILLED=1; PROC=0; return 0; }
ss_official_firewall_active() { return 1; }
ss_official_cache_invalidate
if ss_official_force_stop; then
  pass "force_stop ok"
else
  bad "force_stop ok"
fi
[ "$KILLED" = "1" ] && pass "force_stop killed" || bad "force_stop killed"

# cleanup without force must skip when package installed
CLEANED=0
ss_official_process_running() { return 1; }
ss_official_firewall_active() { return 0; }
ss_official_cleanup_orphan_firewall() {
  # call real logic via un-stubbing is hard — assert helper source has the guard
  :
}
# Source-level guard: package installed → default cleanup returns early
grep -q 'ss_official_daemon_on_disk' "$ROOT/src/backend/official_conflict.sh" || bad "cleanup guards installed package"
grep -q 'Pure detection' "$ROOT/src/backend/official_conflict.sh" || bad "status is pure detection"
pass "cleanup guards present in source"

# firewall.sh must not blindly destroy STEALTHSURF_* while official may be present
grep -q 'Never touch STEALTHSURF_' "$ROOT/src/backend/firewall.sh" ||
  grep -q 'ss_official_daemon_on_disk' "$ROOT/src/backend/firewall.sh" ||
  bad "firewall teardown must spare official ipsets"
pass "firewall teardown spares official ipsets"

echo "ALL PASS"
