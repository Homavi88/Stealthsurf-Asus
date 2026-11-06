#!/bin/sh
# Assert CLI update shows terminal progress stages (no live router required).
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail=0
ok() { echo "OK  $1"; }
bad() { echo "FAIL $1"; fail=$((fail + 1)); }

HELPER="$ROOT/src/backend/_helper.sh"
BACKUP="$ROOT/src/backend/backup.sh"
VERSION="$ROOT/src/backend/version.sh"
LOGGING="$ROOT/src/backend/logging.sh"
CLI="$ROOT/src/backend/stealthsurf.sh"

# --- Source markers ---
grep -q 'ss_console_enabled' "$HELPER" && ok "ss_console_enabled helper" || bad "ss_console_enabled"
grep -q 'ss_progress_begin' "$HELPER" && ok "ss_progress_begin" || bad "ss_progress_begin"
grep -q 'ss_progress_step' "$HELPER" && ok "ss_progress_step" || bad "ss_progress_step"
grep -q 'ss_progress_end' "$HELPER" && ok "ss_progress_end" || bad "ss_progress_end"
grep -q 'ss_curl_download' "$HELPER" && ok "ss_curl_download" || bad "ss_curl_download"
grep -q -- '--progress-bar' "$HELPER" && ok "curl progress-bar flag" || bad "curl progress-bar"
grep -q 'ss_console' "$LOGGING" && ok "logging mirrors to console" || bad "logging console"

grep -q 'ss_progress_begin "StealthSurf update"' "$BACKUP" && ok "update banner" || bad "update banner"
grep -q 'Checking GitHub / resolving download URL' "$BACKUP" && ok "stage: github" || bad "stage github"
grep -q 'Downloading release' "$BACKUP" && ok "stage: download" || bad "stage download"
grep -q 'Validating archive' "$BACKUP" && ok "stage: validate" || bad "stage validate"
grep -q 'Extracting and installing files' "$BACKUP" && ok "stage: extract" || bad "stage extract"
grep -q 'Remounting UI / rewriting hooks' "$BACKUP" && ok "stage: remount" || bad "stage remount"
grep -q 'Refreshing version.json' "$BACKUP" && ok "stage: version.json" || bad "stage version"
grep -q 'ss_curl_download' "$BACKUP" && ok "update uses ss_curl_download" || bad "update curl helper"

grep -q 'Checking GitHub for latest release' "$VERSION" && ok "version.check status" || bad "version.check status"
grep -q 'Checking whether an update is available' "$VERSION" && ok "update-if-available status" || bad "update-if status"

# CLI must not silence stderr during force-update (progress lives there)
if grep -E 'ss_version_check >/dev/null 2>&1' "$CLI" >/dev/null; then
  bad "CLI still redirects stderr on version check during update"
else
  ok "CLI keeps stderr for progress during update"
fi
grep -q 'ss_version_check >/dev/null' "$CLI" && ok "CLI silences JSON stdout only" || bad "CLI stdout silence"

# --- Runtime: progress helpers print to stderr, never stdout ---
export ADDON_TAG=stealthsurf
export ADDON_LOGS_DIR="$TMP/logs"
export SS_PROGRESS=1
mkdir -p "$ADDON_LOGS_DIR"

# Minimal stubs so sourcing _helper does not need full router env
ADDON_SHARE_DIR="$TMP"
ADDON_TMP_DIR="$TMP/tmp"
ADDON_DATA_DIR="$TMP/data"
ADDON_BACKUP_DIR="$TMP/bak"
SS_CONF_FILE="$TMP/conf"
SS_POLICIES_FILE="$TMP/policies.json"
SS_ROUTING_FILE="$TMP/routing.json"
SS_OUTBOUNDS_FILE="$TMP/outbounds.json"
SS_CACHE_KEYS="$TMP/keys.json"
SS_CACHE_SUBSCRIPTIONS="$TMP/subs.json"
SS_CACHE_CONFIGS="$TMP/configs.json"
SS_ENDPOINTS_FILE="$TMP/endpoints.json"
export ADDON_SHARE_DIR ADDON_TMP_DIR ADDON_DATA_DIR ADDON_BACKUP_DIR
export SS_CONF_FILE SS_POLICIES_FILE SS_ROUTING_FILE SS_OUTBOUNDS_FILE
export SS_CACHE_KEYS SS_CACHE_SUBSCRIPTIONS SS_CACHE_CONFIGS SS_ENDPOINTS_FILE

# shellcheck disable=SC1090
. "$HELPER"

# Silence logger noise in CI
logger() { :; }

out=$(mktemp)
err=$(mktemp)

ss_progress_begin "StealthSurf update" 7 >"$out" 2>"$err"
ss_progress_step "Backup before update" >>"$out" 2>>"$err"
ss_progress_step "Checking GitHub / resolving download URL" >>"$out" 2>>"$err"
ss_progress_step "Downloading release" >>"$out" 2>>"$err"
ss_progress_step "Validating archive" >>"$out" 2>>"$err"
ss_progress_step "Extracting and installing files" >>"$out" 2>>"$err"
ss_progress_step "Remounting UI / rewriting hooks" >>"$out" 2>>"$err"
ss_progress_step "Refreshing version.json" >>"$out" 2>>"$err"
ss_progress_end "done — now 1.0.29" >>"$out" 2>>"$err"

if [ -s "$out" ]; then
  bad "progress leaked to stdout: $(cat "$out")"
else
  ok "progress stays off stdout"
fi

grep -q '======== StealthSurf update ========' "$err" && ok "banner on stderr" || bad "banner on stderr"
grep -q '\[1/7\].*Backup before update' "$err" && ok "step1 stderr" || bad "step1 stderr"
grep -q '\[3/7\].*Downloading release' "$err" && ok "step3 stderr" || bad "step3 stderr"
grep -q '\[7/7\].*Refreshing version.json' "$err" && ok "step7 stderr" || bad "step7 stderr"
grep -q '======== done — now 1.0.29 ========' "$err" && ok "end banner stderr" || bad "end banner"

# SS_PROGRESS=0 must silence console
SS_PROGRESS=0
: >"$err"
ss_progress_begin "hidden" 3 >"$out" 2>"$err"
ss_progress_step "should not show" >>"$out" 2>>"$err"
if [ -s "$err" ]; then
  bad "SS_PROGRESS=0 still printed: $(cat "$err")"
else
  ok "SS_PROGRESS=0 silences console"
fi

# ss_info goes to stderr when progress forced on
SS_PROGRESS=1
: >"$out"
: >"$err"
ss_info "hello status" >"$out" 2>"$err"
grep -q 'INFO: hello status' "$err" && ok "ss_info on stderr" || bad "ss_info on stderr"
[ ! -s "$out" ] && ok "ss_info not on stdout" || bad "ss_info leaked stdout"

if [ "$fail" -ne 0 ]; then
  echo "FAILED: $fail"
  exit 1
fi
echo "All update-progress tests passed"
