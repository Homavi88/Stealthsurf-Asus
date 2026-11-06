#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export ADDON_TAG=stealthsurf
export ADDON_VERSION=1.0.8
export ADDON_REPO=Homavi88/Stealthsurf-Asus
export ADDON_RELEASE_TGZ="https://github.com/${ADDON_REPO}/releases/latest/download/asuswrt-merlin-stealthsurf.tar.gz"
export ADDON_RELEASE_API="https://api.github.com/repos/${ADDON_REPO}/releases/latest"
export ADDON_RELEASES_API="https://api.github.com/repos/${ADDON_REPO}/releases"
export ADDON_RELEASE_ASSET="asuswrt-merlin-stealthsurf.tar.gz"
export ADDON_SHARE_DIR="$TMP"
export ADDON_WEB_DIR="$TMP/web"
export ADDON_TMP_DIR="$TMP/tmp"
export ADDON_LOGS_DIR="$TMP/logs"
export ADDON_DATA_DIR="$TMP/data"
export SS_VERSION_FILE="$TMP/version.json"
export SS_VERSIONS_FILE="$TMP/versions.json"
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

# Human changelog from GitHub-style body
notes=$(ss_version_humanize_notes "$(printf '%s\n' \
  '## Whats Changed' \
  '* Fix firewall blackhole by @a in #14' \
  '* Add update changelog modal by @a in #20' \
  '* docs: CLI cheatsheet by @a in #16')" "v1.0.17" "Release")
assert_eq "$(printf '%s' "$notes" | jq -r '.headline')" "Новые возможности и исправления ошибок" "humanize headline"
assert_eq "$(printf '%s' "$notes" | jq -r '.fixes|length')" "1" "humanize fixes"
feat_n=$(printf '%s' "$notes" | jq -r '.features|length')
[ "$feat_n" -ge 1 ] && echo "OK  humanize features" || {
  echo "FAIL humanize features (got $feat_n)"
  fail=$((fail + 1))
}
printf '%s' "$notes" | jq -e 'has("summary") and has("features") and has("fixes")' >/dev/null && echo "OK  humanize json shape" || {
  echo "FAIL humanize json shape"
  fail=$((fail + 1))
}
ss_version_write "1.0.16" "1.0.17" "v1.0.17" "https://example/rel" "" "https://example/dl.tgz" "$notes" >/dev/null
assert_eq "$(jq -r '.changelog.headline' "$SS_VERSION_FILE")" "Новые возможности и исправления ошибок" "changelog persisted"

grep -q 'openUpdateModal' "$ROOT/src/ui/app.js" && echo "OK  UI changelog modal" || {
  echo "FAIL UI changelog modal"
  fail=$((fail + 1))
}
grep -q 'updateModal' "$ROOT/src/ui/index.asp" && echo "OK  ASP update modal" || {
  echo "FAIL ASP update modal"
  fail=$((fail + 1))
}

# Tag normalize + release entry from fixture
assert_eq "$(ss_version_tag_normalize 1.0.16)" "v1.0.16" "tag normalize bare"
assert_eq "$(ss_version_tag_normalize v1.0.16)" "v1.0.16" "tag normalize v-prefix"

cat >"$TMP/fake-release.json" <<'EOF'
{
  "tag_name": "v1.0.16",
  "name": "Release v1.0.16",
  "html_url": "https://example/rel/v1.0.16",
  "published_at": "2026-11-06T00:00:00Z",
  "body": "## Whats Changed\n* Fix firewall blackhole by @a in #14\n* Add routing rule builder by @a in #20\n",
  "assets": [
    {"name": "asuswrt-merlin-stealthsurf.tar.gz", "browser_download_url": "https://example/dl/v1.0.16.tgz"}
  ]
}
EOF
entry=$(ss_version_release_entry "$TMP/fake-release.json" "1.0.20")
assert_eq "$(printf '%s' "$entry" | jq -r '.direction')" "older" "release entry older=rollback"
assert_eq "$(printf '%s' "$entry" | jq -r '.download_url')" "https://example/dl/v1.0.16.tgz" "release entry download_url"
assert_eq "$(printf '%s' "$entry" | jq -r '.changelog.fixes|length')" "1" "release entry changelog fixes"
feat_entry=$(printf '%s' "$entry" | jq -r '.changelog.features|length')
[ "$feat_entry" -ge 1 ] && echo "OK  release entry changelog features" || {
  echo "FAIL release entry changelog features (got $feat_entry)"
  fail=$((fail + 1))
}

# Cached fetch_tag prefers versions.json
jq -nc --argjson rel "$entry" '{installed:"1.0.20",releases:[$rel]}' >"$SS_VERSIONS_FILE"
cached=$(ss_version_fetch_tag v1.0.16)
assert_eq "$(printf '%s' "$cached" | jq -r '.tag')" "v1.0.16" "fetch_tag from cache"

grep -q 'versionsModal' "$ROOT/src/ui/index.asp" && echo "OK  ASP versions modal" || {
  echo "FAIL ASP versions modal"
  fail=$((fail + 1))
}
grep -q 'installSelectedVersion' "$ROOT/src/ui/app.js" && echo "OK  UI installSelectedVersion" || {
  echo "FAIL UI installSelectedVersion"
  fail=$((fail + 1))
}
grep -q 'ss_version_install_tag' "$ROOT/src/backend/version.sh" && echo "OK  install_tag helper" || {
  echo "FAIL install_tag helper"
  fail=$((fail + 1))
}
grep -q 'listversions' "$ROOT/src/backend/service_event.sh" && echo "OK  service listversions" || {
  echo "FAIL service listversions"
  fail=$((fail + 1))
}
grep -q 'install-version | switch-version | rollback' "$ROOT/src/backend/stealthsurf.sh" && echo "OK  CLI install-version" || {
  echo "FAIL CLI install-version"
  fail=$((fail + 1))
}
grep -q 'pinned download failed' "$ROOT/src/backend/backup.sh" && echo "OK  pinned URL no latest fallback" || {
  echo "FAIL pinned URL no latest fallback"
  fail=$((fail + 1))
}

# CLI help / aliases present in source
grep -q 'uninstall | remove | purge | un)' "$ROOT/src/backend/stealthsurf.sh" && echo "OK  uninstall aliases" || {
  echo "FAIL uninstall aliases"
  fail=$((fail + 1))
}
grep -q 'uninstall refuses without confirmation' "$ROOT/src/backend/stealthsurf.sh" && echo "OK  uninstall confirm" || {
  echo "FAIL uninstall confirm"
  fail=$((fail + 1))
}
grep -q 'ss_doctor' "$ROOT/src/backend/mount.sh" && echo "OK  doctor" || {
  echo "FAIL doctor"
  fail=$((fail + 1))
}
grep -q 'live addon untouched' "$ROOT/src/backend/backup.sh" && echo "OK  atomic update" || {
  echo "FAIL atomic update"
  fail=$((fail + 1))
}
# Boot may auto-check GitHub in-browser, but must never form-submit checkupdate
if grep -n 'triggerService("checkupdate"' "$ROOT/src/ui/app.js" >/dev/null 2>&1; then
  echo "FAIL no auto checkupdate submit"
  fail=$((fail + 1))
elif grep -q 'checkUpdateFromGithub({ quiet: true, skipAutoModal: true })' "$ROOT/src/ui/app.js"; then
  echo "OK  no auto checkupdate submit"
else
  echo "FAIL no auto checkupdate submit"
  fail=$((fail + 1))
fi
grep -q 'force-update | update-force | uf' "$ROOT/src/backend/stealthsurf.sh" && echo "OK  force-update" || {
  echo "FAIL force-update"
  fail=$((fail + 1))
}
grep -q 'ss_cli_help' "$ROOT/src/backend/stealthsurf.sh" && echo "OK  help" || {
  echo "FAIL help"
  fail=$((fail + 1))
}
grep -q 'start | up | on)' "$ROOT/src/backend/stealthsurf.sh" && echo "OK  short start" || {
  echo "FAIL short start"
  fail=$((fail + 1))
}
grep -q 'sync | sy)' "$ROOT/src/backend/stealthsurf.sh" && echo "OK  short sync" || {
  echo "FAIL short sync"
  fail=$((fail + 1))
}
grep -q 'ss_cli_menu' "$ROOT/src/backend/stealthsurf.sh" && echo "OK  menu" || {
  echo "FAIL menu"
  fail=$((fail + 1))
}
grep -q '/opt/bin/ssurf' "$ROOT/src/backend/install.sh" && echo "OK  ssurf symlink" || {
  echo "FAIL ssurf symlink"
  fail=$((fail + 1))
}

# UI binds check/update (Update passes tag via triggerWebUiUpdate → triggerService("update"))
grep -q 'checkupdate' "$ROOT/src/ui/app.js" && echo "OK  UI checkupdate" || {
  echo "FAIL UI checkupdate"
  fail=$((fail + 1))
}
grep -q 'triggerService("update"' "$ROOT/src/ui/app.js" && echo "OK  UI update" || {
  echo "FAIL UI update"
  fail=$((fail + 1))
}
grep -q 'function triggerWebUiUpdate' "$ROOT/src/ui/app.js" && echo "OK  UI triggerWebUiUpdate" || {
  echo "FAIL UI triggerWebUiUpdate"
  fail=$((fail + 1))
}
grep -q 'tag // .version' "$ROOT/src/backend/service_event.sh" && echo "OK  update payload tag/version" || {
  echo "FAIL update payload tag/version"
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
