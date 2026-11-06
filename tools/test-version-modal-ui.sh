#!/bin/sh
# Regression: version/GitHub lookup must NOT use Merlin start_apply / action_script.
# Mirror XrayUI Version.vue — browser fetch to api.github.com + overlay modal.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
APP="$ROOT/src/ui/app.js"
ASP="$ROOT/src/ui/index.asp"

fail=0
ok() { echo "OK  $1"; }
bad() { echo "FAIL $1"; fail=$((fail + 1)); }

# Client-side GitHub helpers present
grep -q 'fetchGithubJson' "$APP" && ok "fetchGithubJson helper" || bad "fetchGithubJson helper"
grep -q 'api.github.com/repos/' "$APP" && ok "GitHub releases API URL" || bad "GitHub releases API URL"
grep -q 'checkUpdateFromGithub' "$APP" && ok "checkUpdateFromGithub" || bad "checkUpdateFromGithub"
grep -q 'buildVersionsFromGithubList' "$APP" && ok "buildVersionsFromGithubList" || bad "buildVersionsFromGithubList"
grep -q 'requestVersionsList' "$APP" && ok "requestVersionsList" || bad "requestVersionsList"

# requestVersionsList must fetch — not submit apply form
if grep -n 'function requestVersionsList\|async function requestVersionsList' "$APP" >/dev/null; then
  # Extract requestVersionsList body roughly and ensure no form.submit / action_script
  awk '
    /async function requestVersionsList|function requestVersionsList/ {infn=1}
    infn && /^async function |^function / && !/requestVersionsList/ {infn=0}
    infn {print}
  ' "$APP" >"$ROOT/../.tmp-requestVersionsList.js" 2>/dev/null || true
fi
TMP=$(mktemp)
awk '
  /async function requestVersionsList|function requestVersionsList/ {infn=1}
  infn {
    print
    if (infn && NR>1 && /^(async )?function / && !/requestVersionsList/) {exit}
  }
' "$APP" >"$TMP"
# Stop at next top-level function after body — simpler checks on whole file sections:

# Must NOT call triggerService for listversions anymore
if grep -n 'triggerService("listversions"' "$APP" >/dev/null 2>&1; then
  bad "still triggerService(listversions) — would hit start_apply"
else
  ok "no triggerService(listversions)"
fi
if grep -n 'triggerService("versions"' "$APP" >/dev/null 2>&1; then
  bad "still triggerService(versions)"
else
  ok "no triggerService(versions)"
fi

# checkupdate must not form-submit via triggerService call sites
if grep -n 'triggerService("checkupdate"' "$APP" >/dev/null 2>&1; then
  bad "still triggerService(checkupdate) call sites"
else
  ok "no triggerService(checkupdate) call sites"
fi

# Buttons bind to client helpers
grep -q 'checkUpdateFromGithub({ openModalIfUpdate: true })' "$APP" && ok "btnCheckUpdate uses client fetch" || bad "btnCheckUpdate uses client fetch"
grep -q 'requestVersionsList(false)' "$APP" && ok "versions UI calls requestVersionsList" || bad "versions UI calls requestVersionsList"

# triggerService must refuse read-only version actions before form.submit
grep -q 'action === "checkupdate"' "$APP" && ok "triggerService guards checkupdate" || bad "triggerService guards checkupdate"
grep -q 'action === "listversions" || action === "versions"' "$APP" && ok "triggerService guards listversions" || bad "triggerService guards listversions"

# Modal has in-overlay loading/status (not Merlin Loading)
grep -q 'versionsStatus' "$ASP" && ok "ASP versionsStatus element" || bad "ASP versionsStatus element"
grep -q 'setVersionsModalStatus' "$APP" && ok "setVersionsModalStatus helper" || bad "setVersionsModalStatus helper"
grep -q 'ss-versions-status' "$ASP" && ok "ASP versions status CSS" || bad "ASP versions status CSS"

# Wait times for checkupdate/listversions must not remain (would imply apply path)
if grep -nE 'checkupdate.*wait|listversions.*wait|versions.*wait = 20' "$APP" >/dev/null 2>&1; then
  if grep -n 'else if (action === "checkupdate" || action === "listversions"' "$APP" >/dev/null 2>&1; then
    bad "triggerService still assigns action_wait for checkupdate/listversions"
  else
    ok "no action_wait for read-only version actions"
  fi
else
  ok "no action_wait for read-only version actions"
fi

# Labels for checkupdate/listversions should not drive Merlin apply messaging
if awk '/const labels = \{/,/^\s*\};/' "$APP" | grep -q 'checkupdate:'; then
  bad "apply labels still include checkupdate"
else
  ok "apply labels omit checkupdate"
fi
if awk '/const labels = \{/,/^\s*\};/' "$APP" | grep -q 'listversions:'; then
  bad "apply labels still include listversions"
else
  ok "apply labels omit listversions"
fi

# Install/update still go through triggerService (mutating ops OK with apply)
grep -q 'triggerService("installversion"' "$APP" && ok "install still uses triggerService" || bad "install still uses triggerService"
grep -q 'triggerService("update"' "$APP" && ok "update still uses triggerService" || bad "update still uses triggerService"

# Boot auto-notifies via browser GitHub fetch — must NOT form-submit checkupdate
if grep -n 'triggerService("checkupdate"' "$APP" >/dev/null 2>&1; then
  bad "boot/path still form-submits checkupdate"
else
  ok "no form-submit checkupdate anywhere"
fi
grep -q 'shouldAutoShowUpdateModal' "$APP" && ok "auto update modal gate" || bad "auto update modal gate"
grep -q 'snoozeUpdateNotice' "$APP" && ok "later = snooze" || bad "later = snooze"
grep -q 'dismissUpdateNotice' "$APP" && ok "close = dismiss" || bad "close = dismiss"
grep -q 'value="Обновить"' "$ASP" && ok "modal Update button RU" || bad "modal Update button RU"
grep -q 'Обновить позднее' "$ASP" && ok "modal Later button RU" || bad "modal Later button RU"
grep -q 'Закрыть уведомление' "$ASP" && ok "modal Dismiss button RU" || bad "modal Dismiss button RU"
grep -q 'quiet: true, skipAutoModal: true' "$APP" && ok "boot quiet GitHub check" || bad "boot quiet GitHub check"

rm -f "$TMP"

if [ "$fail" -ne 0 ]; then
  echo "FAILED: $fail"
  exit 1
fi
echo "All version-modal UI regressions passed"
