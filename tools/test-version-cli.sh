#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export ADDON_TAG=stealthsurf
export ADDON_VERSION=1.0.6
export ADDON_REPO=Homavi88/Stealthsurf-Asus
export ADDON_RELEASE_TGZ="https://github.com/${ADDON_REPO}/releases/latest/download/asuswrt-merlin-stealthsurf.tar.gz"
export ADDON_RELEASE_API="https://api.github.com/repos/${ADDON_REPO}/releases/latest"
export ADDON_SHARE_DIR="$TMP"
export ADDON_WEB_DIR="$TMP/web"
export ADDON_TMP_DIR="$TMP/tmp"
export ADDON_LOGS_DIR="$TMP/logs"
export ADDON_DATA_DIR="$TMP/data"
export SS_VERSION_FILE="$TMP/version.json"
mkdir -p "$ADDON_WEB_DIR" "$ADDON_TMP_DIR" "$ADDON_LOGS_DIR" "$ADDON_DATA_DIR"

ss_ensure_dirs() { mkdir -p "$ADDON_SHARE_DIR" "$ADDON_WEB_DIR" "$ADDON_TMP_DIR"; }
ss_info() { :; }
ss_ok() { :; }
ss_warn() { :; }
ss_error() { echo "ERR $*" >&2; }
ss_activity() { :; }
ss_log() { :; }

# shellcheck disable=SC1091
. "$ROOT/src/backend/version.sh"

fail=0
assert_eq() {
  if [ "$1" = "$2" ]; then
    echo "OK  $3"
  else
    echo "FAIL $3 (got='$1' want='$2')"
    fail=$((fail + 1))
  fi
}

assert_eq "$(ss_version_cmp 1.0.5 1.0.4)" "1" "cmp newer"
assert_eq "$(ss_version_cmp 1.0.3 1.0.5)" "-1" "cmp older"
assert_eq "$(ss_version_cmp v1.0.5 1.0.5)" "0" "cmp equal v-prefix"

ss_version_write "1.0.5" "1.0.6" "v1.0.6" "https://example/rel" "" "https://example/dl.tgz" >/dev/null
assert_eq "$(jq -r '.update_available' "$SS_VERSION_FILE")" "true" "update_available true"
assert_eq "$(jq -r '.download_url' "$SS_VERSION_FILE")" "https://example/dl.tgz" "download_url persisted"
assert_eq "$(ss_version_download_url)" "https://example/dl.tgz" "download_url getter"

ss_version_write "1.0.6" "1.0.6" "v1.0.6" "https://example/rel" "" "https://example/dl.tgz" >/dev/null
assert_eq "$(jq -r '.update_available' "$SS_VERSION_FILE")" "false" "uptodate"

# CLI help / aliases present in source
grep -q 'uninstall | remove | purge' "$ROOT/src/backend/stealthsurf.sh" && echo "OK  uninstall aliases" || {
  echo "FAIL uninstall aliases"
  fail=$((fail + 1))
}
grep -q 'force-update' "$ROOT/src/backend/stealthsurf.sh" && echo "OK  force-update" || {
  echo "FAIL force-update"
  fail=$((fail + 1))
}
grep -q 'ss_cli_help' "$ROOT/src/backend/stealthsurf.sh" && echo "OK  help" || {
  echo "FAIL help"
  fail=$((fail + 1))
}

# UI binds check/update
grep -q 'checkupdate' "$ROOT/src/ui/app.js" && echo "OK  UI checkupdate" || {
  echo "FAIL UI checkupdate"
  fail=$((fail + 1))
}
grep -q 'triggerService("update"' "$ROOT/src/ui/app.js" && echo "OK  UI update" || {
  echo "FAIL UI update"
  fail=$((fail + 1))
}
grep -q 'StealthSurf UI hook begin' "$ROOT/src/backend/hooks.sh" && echo "OK  hook refresh payload" || {
  echo "FAIL hook"
  fail=$((fail + 1))
}

if [ "$fail" -ne 0 ]; then
  echo "FAILED: $fail"
  exit 1
fi
echo "All version/CLI tests passed"
