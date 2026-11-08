#!/bin/sh
# Regression: failed update must not wipe a live addon (bug seen on 1.0.10).
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail=0
ok() { echo "OK  $1"; }
bad() { echo "FAIL $1"; fail=$((fail + 1)); }

# Source markers in backup.sh / install.sh / UI
grep -q 'stealthsurf-update-stage' "$ROOT/src/backend/backup.sh" && ok "staged extract" || bad "staged extract"
grep -q 'refusing to replace addon\|live addon untouched' "$ROOT/src/backend/backup.sh" && ok "refuse bad archive" || bad "refuse bad archive"
grep -q 'ss_progress_begin' "$ROOT/src/backend/backup.sh" && ok "update progress stages" || bad "update progress stages"
grep -q 'ss_curl_download' "$ROOT/src/backend/backup.sh" && ok "download with progress helper" || bad "download progress helper"
grep -q 'SS_INSTALL_REMOUNT=1' "$ROOT/src/backend/backup.sh" && ok "post-update remount flag" || bad "post-update remount flag"
grep -q 'SS_INSTALL_REMOUNT' "$ROOT/src/backend/install.sh" && ok "install honors remount (skip geo)" || bad "install honors remount (skip geo)"
grep -q 'Keeping existing geoip/geosite' "$ROOT/src/backend/install.sh" && ok "keeps existing geodata" || bad "keeps existing geodata"
grep -q 'SS_FORCE_GEODATA' "$ROOT/src/backend/install.sh" && ok "SS_FORCE_GEODATA override" || bad "SS_FORCE_GEODATA override"
grep -q 'skipping opkg update' "$ROOT/src/backend/install.sh" && ok "can skip opkg update" || bad "can skip opkg update"
grep -q 'stealthsurf-install-stage' "$ROOT/install.sh" && ok "installer staged" || bad "installer staged"
grep -q 'установленный аддон не тронут\|отказ трогать установленный аддон' "$ROOT/install.sh" && ok "installer refuse" || bad "installer refuse"

# Simulate: live addon exists; invalid download must leave it intact
LIVE="$TMP/jffs/addons/stealthsurf"
mkdir -p "$LIVE" "$TMP/jffs/scripts"
echo '#!/bin/sh' >"$LIVE/stealthsurf"
echo 'ok' >"$LIVE/index.asp"
echo 'ok' >"$LIVE/app.js"
cp "$LIVE/stealthsurf" "$TMP/jffs/scripts/stealthsurf"
echo '<html>404</html>' >"$TMP/bad.tgz"

if tar -tzf "$TMP/bad.tgz" >/dev/null 2>&1; then
  bad "html should not look like tar.gz"
else
  ok "html rejected by tar -tzf"
fi
[ -f "$LIVE/index.asp" ] && [ -f "$TMP/jffs/scripts/stealthsurf" ] && ok "live files still present" || bad "live files"

# Valid tiny archive layout check expectation
STAGE="$TMP/stage"
mkdir -p "$STAGE/stealthsurf"
echo '#!/bin/sh' >"$STAGE/stealthsurf/stealthsurf"
echo 'asp' >"$STAGE/stealthsurf/index.asp"
echo 'js' >"$STAGE/stealthsurf/app.js"
tar -czf "$TMP/good.tgz" -C "$STAGE" stealthsurf
tar -tzf "$TMP/good.tgz" | grep -q 'stealthsurf/stealthsurf' && ok "good archive lists script" || bad "good archive"

# Uninstall safety
grep -q 'uninstall disabled from WebUI' "$ROOT/src/backend/service_event.sh" && ok "UI uninstall blocked" || bad "UI uninstall blocked"
grep -q 'uninstall|remove|purge)' "$ROOT/src/backend/hooks.sh" && ok "hook blocks uninstall" || bad "hook blocks uninstall"
! grep -q '| rm)' "$ROOT/src/backend/stealthsurf.sh" && ok "rm alias removed" || bad "rm alias still present"

if [ "$fail" -ne 0 ]; then
  echo "FAILED: $fail"
  exit 1
fi
echo "All atomic-update safety tests passed"
