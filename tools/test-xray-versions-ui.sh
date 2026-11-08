#!/bin/sh
# Regression: Xray-core version list must auto-load via browser GitHub fetch (XrayUI-style).
# Never route xrayversions/listxray through Merlin start_apply.htm for the WebUI list.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
APP="$ROOT/src/ui/app.js"
ASP="$ROOT/src/ui/index.asp"

fail=0
ok() { echo "OK  $1"; }
bad() { echo "FAIL $1"; fail=$((fail + 1)); }

grep -q 'XRAY_GH_RELEASES_API' "$APP" && ok "XRAY_GH_RELEASES_API constant" || bad "XRAY_GH_RELEASES_API constant"
grep -q 'XTLS/Xray-core' "$APP" && ok "XTLS/Xray-core repo" || bad "XTLS/Xray-core repo"
grep -q 'buildXrayVersionsFromGithubList' "$APP" && ok "buildXrayVersionsFromGithubList" || bad "buildXrayVersionsFromGithubList"
grep -q 'requestXrayVersionsList' "$APP" && ok "requestXrayVersionsList" || bad "requestXrayVersionsList"
grep -q 'fetchGithubJson' "$APP" && ok "reuses fetchGithubJson" || bad "reuses fetchGithubJson"

# Modal open auto-loads versions
grep -q 'requestXrayVersionsList({ quiet: true })' "$APP" && ok "xrayModal auto-loads versions" || bad "xrayModal auto-loads versions"

# Refresh button uses client helper (not Merlin apply)
grep -q 'requestXrayVersionsList({ quiet: false })' "$APP" && ok "refresh uses requestXrayVersionsList" || bad "refresh uses requestXrayVersionsList"

# Must NOT form-submit xrayversions/listxray anymore
if grep -n 'triggerService("xrayversions"' "$APP" >/dev/null 2>&1; then
  bad "still triggerService(xrayversions) — would hit start_apply"
else
  ok "no triggerService(xrayversions)"
fi
if grep -n 'triggerService("listxray"' "$APP" >/dev/null 2>&1; then
  bad "still triggerService(listxray)"
else
  ok "no triggerService(listxray)"
fi

# triggerService must redirect read-only xray version actions to browser fetch
grep -q 'action === "xrayversions" || action === "listxray"' "$APP" && ok "triggerService guards xrayversions" || bad "triggerService guards xrayversions"

# UI copy: auto-load, not manual-only
grep -q 'value="Обновить список"' "$ASP" && ok "ASP refresh button label" || bad "ASP refresh button label"
grep -q 'Загрузка релизов Xray-core с GitHub' "$ASP" && ok "ASP loading placeholder" || bad "ASP loading placeholder"
if grep -q 'Нажмите «Загрузить список версий»' "$ASP"; then
  bad "ASP still asks to click load manually"
else
  ok "ASP no longer requires manual load click"
fi

# Install by tag still mutates via triggerService (OK)
grep -q 'triggerService("installxray"' "$APP" && ok "installxray still uses triggerService" || bad "installxray still uses triggerService"

# Installed version marked in the releases list
grep -q 'xrayInstalledVersionHint' "$APP" && ok "xrayInstalledVersionHint" || bad "xrayInstalledVersionHint"
grep -q 'xrayReleaseIsInstalled' "$APP" && ok "xrayReleaseIsInstalled" || bad "xrayReleaseIsInstalled"
grep -q "label-success'>установлена" "$APP" && ok "installed badge in list" || bad "installed badge in list"
grep -q 'ss-xray-current' "$APP" && ok "current row class" || bad "current row class"
grep -q 'ss-xray-current' "$ASP" && ok "ASP current row CSS" || bad "ASP current row CSS"
grep -q 'xrayVersionsHint' "$ASP" && ok "ASP versions hint" || bad "ASP versions hint"
grep -q 'Переустановить' "$APP" && ok "reinstall button for current" || bad "reinstall button for current"

# Backend cache fallback still lists from same GitHub repo
grep -q 'XTLS/Xray-core/releases' "$ROOT/src/backend/xray_bin.sh" && ok "backend lists XTLS/Xray-core" || bad "backend lists XTLS/Xray-core"
grep -q 'per_page=30' "$ROOT/src/backend/_globals.sh" && ok "backend per_page=30" || bad "backend per_page=30"

if [ "$fail" -ne 0 ]; then
  echo "FAILED: $fail"
  exit 1
fi
echo "All xray-versions UI regressions passed"
