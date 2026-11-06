#!/bin/sh
# Regression: API-key balance refresh must NOT use Merlin start_apply / action_script.
# Mirror checkupdate fix — browser fetch to api.stealthsurf.net + balances.json poll.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
APP="$ROOT/src/ui/app.js"
ASP="$ROOT/src/ui/index.asp"

fail=0
ok() { echo "OK  $1"; }
bad() { echo "FAIL $1"; fail=$((fail + 1)); }

# Client-side StealthSurf balance helpers
grep -q 'SS_API_BASE' "$APP" && ok "SS_API_BASE constant" || bad "SS_API_BASE constant"
grep -q 'api.stealthsurf.net' "$APP" && ok "StealthSurf API host" || bad "StealthSurf API host"
grep -q 'refreshBalancesFromApi' "$APP" && ok "refreshBalancesFromApi" || bad "refreshBalancesFromApi"
grep -q 'fetchStealthsurfProfile' "$APP" && ok "fetchStealthsurfProfile" || bad "fetchStealthsurfProfile"
grep -q 'loadBalancesCache' "$APP" && ok "loadBalancesCache" || bad "loadBalancesCache"
grep -q 'requestBalancesRefresh' "$APP" && ok "requestBalancesRefresh" || bad "requestBalancesRefresh"
grep -q 'balancesCacheIsStale' "$APP" && ok "balancesCacheIsStale" || bad "balancesCacheIsStale"

# requestBalancesRefresh must NOT call triggerService / form.submit
TMP=$(mktemp)
awk '
  /function requestBalancesRefresh/ {infn=1}
  infn {
    print
    if (infn && NR > 1 && /^(async )?function / && !/requestBalancesRefresh/) {exit}
  }
' "$APP" >"$TMP"
if grep -Eq 'triggerService|form\.submit|action_script|showLoading|start_apply' "$TMP"; then
  bad "requestBalancesRefresh still uses Merlin apply path"
else
  ok "requestBalancesRefresh has no apply/submit/showLoading"
fi
rm -f "$TMP"

TMP=$(mktemp)
awk '
  /async function refreshBalancesFromApi|function refreshBalancesFromApi/ {infn=1}
  infn {
    print
    if (infn && NR > 1 && /^(async )?function / && !/refreshBalancesFromApi/) {exit}
  }
' "$APP" >"$TMP"
if grep -Eq 'triggerService|form\.submit|action_script|showLoading|start_apply' "$TMP"; then
  bad "refreshBalancesFromApi still uses Merlin apply path"
else
  ok "refreshBalancesFromApi has no apply/submit/showLoading"
fi
grep -q 'fetchStealthsurfProfile\|SS_API_BASE' "$TMP" && ok "refreshBalancesFromApi hits StealthSurf API" || bad "refreshBalancesFromApi hits StealthSurf API"
rm -f "$TMP"

# No call-site form-submit for balances
if grep -nE 'triggerService\("balances"|triggerService\("refreshbalances"|triggerService\("balance"' "$APP" >/dev/null 2>&1; then
  bad "still triggerService(balances) call sites — would hit start_apply"
else
  ok "no triggerService(balances) call sites"
fi

# triggerService must refuse balances before form.submit (guard)
grep -q 'action === "balances" || action === "refreshbalances" || action === "balance"' "$APP" && \
  ok "triggerService guards balances" || bad "triggerService guards balances"

# Guard must call quiet refresh, not fall through to form.submit
TMP=$(mktemp)
awk '
  /function triggerService/ {infn=1}
  infn {
    print
    if (infn && NR > 1 && /^function / && !/triggerService/) {exit}
  }
' "$APP" >"$TMP"
# Within triggerService, balances branch should return before form.submit
if awk '
  /action === "balances"/ {bal=1}
  bal && /requestBalancesRefresh/ {hit=1}
  bal && /return;/ {ret=1; exit}
  END {exit (hit && ret) ? 0 : 1}
' "$TMP"; then
  ok "balances guard returns via requestBalancesRefresh"
else
  bad "balances guard returns via requestBalancesRefresh"
fi
rm -f "$TMP"

# Wait / Merlin labels for balances must not remain on apply path
if grep -nE 'action === "balances".*wait|else if \(action === "balances"' "$APP" >/dev/null 2>&1; then
  bad "triggerService still assigns action_wait for balances"
else
  ok "no action_wait for balances"
fi
if awk '/const labels = \{/,/^\s*\};/' "$APP" | grep -Eq 'balances:|refreshbalances:|^[[:space:]]*balance:'; then
  bad "apply labels still include balances"
else
  ok "apply labels omit balances"
fi

# Keys modal open uses quiet refresh / cache — not apply
grep -q 'keysModal' "$APP" && ok "keysModal open handler" || bad "keysModal open handler"
grep -q 'loadBalancesCache()' "$APP" && ok "modal loads balances.json cache" || bad "modal loads balances.json cache"
grep -q 'requestBalancesRefresh(true, { quiet: true })' "$APP" && \
  ok "stale modal refresh is quiet" || bad "stale modal refresh is quiet"

# Manual button binds to requestBalancesRefresh (quiet path), not triggerService
grep -q 'btnRefreshBalance' "$ASP" && ok "ASP refresh balance button" || bad "ASP refresh balance button"
grep -q 'btnRefreshBalance' "$APP" && ok "app binds btnRefreshBalance" || bad "app binds btnRefreshBalance"
if grep -A2 'btnRefreshBalance' "$APP" | grep -q 'requestBalancesRefresh'; then
  ok "Обновить баланс uses requestBalancesRefresh"
else
  bad "Обновить баланс uses requestBalancesRefresh"
fi

# Authorization header for profile fetch
grep -q 'Authorization: "Bearer "' "$APP" && ok "Bearer auth for /profile" || bad "Bearer auth for /profile"
grep -q '/profile' "$APP" && ok "GET /profile path" || bad "GET /profile path"

# Settings modal open must stay on fetchJson (no apply)
TMP=$(mktemp)
awk '
  /async function openSettingsModal|function openSettingsModal/ {infn=1}
  infn {
    print
    if (infn && NR > 1 && /^(async )?function / && !/openSettingsModal/) {exit}
  }
' "$APP" >"$TMP"
if grep -Eq 'triggerService|form\.submit|showLoading|start_apply' "$TMP"; then
  bad "openSettingsModal uses Merlin apply"
else
  ok "openSettingsModal is quiet fetchJson"
fi
grep -q 'settings.json' "$TMP" && ok "settings open reads settings.json" || bad "settings open reads settings.json"
rm -f "$TMP"

# Backend CLI / service-event still available for SSH
grep -q 'balances | refreshbalances | balance)' "$ROOT/src/backend/service_event.sh" && \
  ok "service-event balances retained" || bad "service-event balances retained"
grep -q 'balances | balance | bal)' "$ROOT/src/backend/stealthsurf.sh" && \
  ok "CLI bal retained" || bad "CLI bal retained"

if [ "$fail" -ne 0 ]; then
  echo "FAILED: $fail"
  exit 1
fi
echo "All balances-ui regressions passed"
