#!/bin/sh
# Unit tests for backup helpers (no router / no restart)
set -e
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export ADDON_TAG=ssurf
export BACKUP_ROOT="$TMP/root"
export ADDON_SHARE_DIR="$BACKUP_ROOT/opt/share/ssurf"
export ADDON_WEB_DIR="$TMP/www"
export ADDON_TMP_DIR="$TMP/tmp"
export ADDON_USER_SCRIPTS_DIR="$BACKUP_ROOT/jffs/ssurf_custom"
export XRAY_CONFIG_DIR="$BACKUP_ROOT/opt/etc/xray/ssurf"
export XRAY_CONFIG_FILE="$XRAY_CONFIG_DIR/config.json"
export XRAYUI_CONFIG_FILE="$BACKUP_ROOT/opt/etc/ssurf.conf"
mkdir -p "$ADDON_SHARE_DIR/backup" "$ADDON_WEB_DIR" "$ADDON_TMP_DIR" \
  "$ADDON_USER_SCRIPTS_DIR" "$XRAY_CONFIG_DIR" "$ADDON_SHARE_DIR/data" \
  "$(dirname "$XRAYUI_CONFIG_FILE")"

log_info() { :; }
log_ok() { :; }
log_warn() { :; }
log_debug() { :; }
log_error() { printf 'ERR %s\n' "$*" >&2; }
update_loading_progress() { :; }
load_xrayui_config() { :; }
generate_xray_config() { echo '{"inbounds":[],"outbounds":[]}' >"$XRAY_CONFIG_FILE"; }
cron_jobs_add() { :; }
restart() { echo restarted >"$TMP/restarted"; }
reconstruct_payload() {
  if [ -n "${TEST_PAYLOAD+set}" ]; then
    printf '%s\n' "$TEST_PAYLOAD"
  else
    printf '%s\n' '{}'
  fi
}

# shellcheck disable=SC1091
. "$ROOT/src/backend/backup.sh"

# ── safe path ───────────────────────────────────────────────────────────────
p=$(backup_safe_path "ssurf-20260101-120000.tar.gz")
test "$p" = "$ADDON_SHARE_DIR/backup/ssurf-20260101-120000.tar.gz"
p=$(backup_safe_path "../etc/passwd") && exit 1 || true
p=$(backup_safe_path "evil.tar.gz") && exit 1 || true
# basename strips directories
p=$(backup_safe_path "/tmp/ssurf-20260101-120000-ok.tar.gz")
test "$(basename "$p")" = "ssurf-20260101-120000-ok.tar.gz"

# ── create + validate ───────────────────────────────────────────────────────
echo '{"outbounds":[]}' >"$XRAY_CONFIG_FILE"
echo 'kill_switch=false' >"$XRAYUI_CONFIG_FILE"
echo 'hook' >"$ADDON_USER_SCRIPTS_DIR/firewall_before_start"
echo 'data' >"$ADDON_SHARE_DIR/data/note.txt"

TEST_PAYLOAD='{"name":"unit"}'
out=$(backup_configuration)
echo "$out" | grep -q 'ssurf-.*-unit.tar.gz'
arch=$(echo "$out" | tail -1)
test -f "$arch"
backup_tar_validate "$arch"
tar -tzf "$arch" | grep -q 'ssurf.conf\|ssurf/config.json\|ssurf_custom'

# Default name is ssurf- (not stealthsurf-)
TEST_PAYLOAD='{}'
out2=$(backup_configuration)
echo "$out2" | grep -q 'ssurf-[0-9].*\.tar.gz'
! echo "$out2" | grep -q 'stealthsurf-'

# ── reject malicious tar ────────────────────────────────────────────────────
bad="$ADDON_SHARE_DIR/backup/ssurf-bad.tar.gz"
# craft tar with /etc/passwd member (GNU/BusyBox)
mkdir -p "$TMP/evil/etc"
echo root >"$TMP/evil/etc/passwd"
(cd "$TMP/evil" && tar -czf "$bad" etc/passwd)
backup_tar_validate "$bad" && exit 1 || true

# ── restore (no real /) via override extract into TMP root simulation ────────
# Re-test validate OK archive still ok
backup_tar_validate "$arch"

# clear single
BACKUP_CLEAR_FILE=$(basename "$arch")
backup_clear
test ! -f "$arch"

# clear all
touch "$ADDON_SHARE_DIR/backup/ssurf-keep.tar.gz"
# empty invalid name should fail safe_path for clear file — use ALL
BACKUP_CLEAR_ALL=1
BACKUP_CLEAR_FILE=
backup_clear
test ! -f "$ADDON_SHARE_DIR/backup/ssurf-keep.tar.gz"

# list is empty-ish
backup_list >/dev/null

# remount does not exit the shell
backup_remount_to_web

# coexistence: source uses ADDON_USER_SCRIPTS_DIR
grep -q 'ADDON_USER_SCRIPTS_DIR' "$ROOT/src/backend/backup.sh"
grep -q 'ssurf-\${timestamp}' "$ROOT/src/backend/backup.sh"
grep -q 'backup_tar_validate' "$ROOT/src/backend/backup.sh"

echo "backup.spec.sh: OK"
