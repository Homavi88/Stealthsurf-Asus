#!/bin/sh
# Regression: WebUI Update must pass GitHub tag so router curl re-check cannot no-op;
# version.json preferred over state.version; script cache-bust after update.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
APP="$ROOT/src/ui/app.js"
ASP="$ROOT/src/ui/index.asp"
SE="$ROOT/src/backend/service_event.sh"
VER="$ROOT/src/backend/version.sh"
MOUNT="$ROOT/src/backend/mount.sh"
BUILD="$ROOT/tools/build.mjs"

fail=0
ok() { echo "OK  $1"; }
bad() { echo "FAIL $1"; fail=$((fail + 1)); }

grep -q 'function triggerWebUiUpdate' "$APP" && ok "triggerWebUiUpdate helper" || bad "triggerWebUiUpdate helper"
grep -q 'function updatePayloadTag' "$APP" && ok "updatePayloadTag helper" || bad "updatePayloadTag helper"
grep -q 'function displayInstalledVersion' "$APP" && ok "displayInstalledVersion helper" || bad "displayInstalledVersion helper"
grep -q 'function hardReloadUi' "$APP" && ok "hardReloadUi helper" || bad "hardReloadUi helper"
grep -q 'triggerWebUiUpdate({ force: false })' "$APP" && ok "modal/banner use triggerWebUiUpdate" || bad "modal/banner use triggerWebUiUpdate"
grep -q 'payload.tag = tag' "$APP" && ok "UI packs tag into update payload" || bad "UI packs tag into update payload"

if grep -n 'triggerService("update", { force: "0" })' "$APP" >/dev/null 2>&1; then
  bad "still bare update force:0 without tag helper"
else
  ok "no bare update force:0 call sites"
fi

grep -q 'displayInstalledVersion(state.version)' "$APP" && ok "renderState uses displayInstalledVersion" || bad "renderState uses displayInstalledVersion"

TMP=$(mktemp)
trap 'rm -f "$TMP"; rm -rf "${TMPDIR_TEST:-}"' EXIT
awk '
  /async function refreshCritical/ {infn=1}
  infn {
    print
    if (/async function refreshSecondary/) exit
  }
' "$APP" >"$TMP"
ver_line=$(grep -nE '^\s*renderVersion\(' "$TMP" | head -1 | cut -d: -f1 || true)
state_line=$(grep -nE '^\s*renderState\(' "$TMP" | head -1 | cut -d: -f1 || true)
if [ -n "$ver_line" ] && [ -n "$state_line" ] && [ "$ver_line" -lt "$state_line" ]; then
  ok "refreshCritical: renderVersion before renderState"
else
  bad "refreshCritical: renderVersion before renderState (ver=$ver_line state=$state_line)"
fi

grep -q 'hardReloadUi' "$APP" && grep -q 'clearUpdateNoticeKeys' "$APP" && ok "post-update hard reload + clear dismiss" || bad "post-update hard reload + clear dismiss"
grep -q '_ssv' "$APP" && ok "cache-bust query on hard reload" || bad "cache-bust query on hard reload"

grep -q 'app.js?v=__SS_VERSION__' "$ASP" && ok "ASP app.js cache-bust placeholder" || bad "ASP app.js cache-bust placeholder"
grep -q 'routing-suggest.js?v=__SS_VERSION__' "$ASP" && ok "ASP routing-suggest cache-bust placeholder" || bad "ASP routing-suggest cache-bust placeholder"
grep -q '__SS_VERSION__' "$MOUNT" && ok "mount bakes ADDON_VERSION into ASP" || bad "mount bakes ADDON_VERSION into ASP"
grep -q '__SS_VERSION__' "$BUILD" && ok "build.mjs replaces __SS_VERSION__" || bad "build.mjs replaces __SS_VERSION__"

grep -q 'tag // .version' "$SE" && ok "service_event update accepts tag/version" || bad "service_event update accepts tag/version"
grep -q 'ss_version_install_tag' "$SE" && ok "service_event update uses install_tag when tag set" || bad "service_event update uses install_tag when tag set"
grep -q 'sh "$ADDON_SCRIPT" version' "$SE" && ok "post-update re-run new script version" || bad "post-update re-run new script version"

awk '
  /^ss_version_update_if_available\(\)/ {infn=1}
  infn {
    print
    if (infn && /^ss_[a-z_]+\(\)/ && !/ss_version_update_if_available/) exit
  }
' "$VER" >"$TMP"
grep -q 'SS_VERSION_FILE' "$TMP" && ok "update_if_available falls back to version.json" || bad "update_if_available falls back to version.json"

export ADDON_TAG=stealthsurf
export ADDON_VERSION=1.0.28
export ADDON_REPO=Homavi88/Stealthsurf-Asus
export ADDON_RELEASE_TGZ="https://github.com/${ADDON_REPO}/releases/latest/download/asuswrt-merlin-stealthsurf.tar.gz"
export ADDON_RELEASE_API="https://api.github.com/repos/${ADDON_REPO}/releases/latest"
export ADDON_RELEASES_API="https://api.github.com/repos/${ADDON_REPO}/releases"
export ADDON_RELEASE_ASSET="asuswrt-merlin-stealthsurf.tar.gz"
TMPDIR_TEST=$(mktemp -d)
export ADDON_SHARE_DIR="$TMPDIR_TEST"
export ADDON_WEB_DIR="$TMPDIR_TEST/web"
export ADDON_TMP_DIR="$TMPDIR_TEST/tmp"
export ADDON_LOGS_DIR="$TMPDIR_TEST/logs"
export ADDON_DATA_DIR="$TMPDIR_TEST/data"
export SS_VERSION_FILE="$TMPDIR_TEST/version.json"
export SS_VERSIONS_FILE="$TMPDIR_TEST/versions.json"
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

assert_eq() {
  if [ "$1" = "$2" ]; then
    ok "$3"
  else
    bad "$3 (got='$1' want='$2')"
  fi
}

assert_eq "$(ss_version_tag_normalize 1.0.29)" "v1.0.29" "UI bare version → tag"
assert_eq "$(ss_version_tag_normalize v1.0.29)" "v1.0.29" "UI v-prefixed tag"

ss_version_write "1.0.28" "1.0.29" "v1.0.29" "https://example/rel" "" "https://example/dl.tgz" >/dev/null
assert_eq "$(jq -r '.update_available' "$SS_VERSION_FILE")" "true" "newer tag → update_available"
assert_eq "$(jq -r '.installed' "$SS_VERSION_FILE")" "1.0.28" "installed stays old until install"

ss_version_check() {
  printf '%s\n' '{"installed":"1.0.28","latest":"1.0.28","update_available":false}'
  return 1
}
ss_update_self() {
  echo "WOULD_UPDATE"
  return 0
}
rc=0
out=$(ss_version_update_if_available 0) || rc=$?
printf '%s' "$out" | grep -q 'WOULD_UPDATE' && ok "no false already-uptodate when version.json has update" || bad "no false already-uptodate when version.json has update"
[ "$rc" = "0" ] && ok "update_if_available exit 0 with cached update" || bad "update_if_available exit 0 with cached update (rc=$rc)"

ss_version_write "1.0.29" "1.0.29" "v1.0.29" "https://example/rel" "" "https://example/dl.tgz" >/dev/null
ss_version_check() {
  cat "$SS_VERSION_FILE"
  return 0
}
ss_update_self() {
  echo "SHOULD_NOT_UPDATE"
  return 0
}
rc=0
out=$(ss_version_update_if_available 0) || rc=$?
[ "$rc" = "2" ] && ok "already up to date exit 2 when no newer" || bad "already up to date exit 2 when no newer (rc=$rc)"
printf '%s' "$out" | grep -q 'SHOULD_NOT_UPDATE' && bad "must not download when up to date" || ok "no download when up to date"

grep -q 'ADDON_VERSION="1.0.29"' "$ROOT/src/backend/_globals.sh" && ok "ADDON_VERSION 1.0.29" || bad "ADDON_VERSION 1.0.29"
grep -q '"version": "1.0.29"' "$ROOT/package.json" && ok "package.json 1.0.29" || bad "package.json 1.0.29"

if [ "$fail" -ne 0 ]; then
  echo "FAILED: $fail"
  exit 1
fi
echo "All webui-update-version regressions passed"
