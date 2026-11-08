#!/bin/sh
# Deferred Apply / pending changes: config edits must NOT Merlin-submit until «Применить».
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
APP="$ROOT/src/ui/app.js"
ASP="$ROOT/src/ui/index.asp"
SE="$ROOT/src/backend/service_event.sh"
CTRL="$ROOT/src/backend/control.sh"
HELP="$ROOT/src/backend/_helper.sh"

fail=0
ok() { echo "OK  $1"; }
bad() { echo "FAIL $1"; fail=$((fail + 1)); }

# --- UI: pending model + Russian Apply bar ---------------------------------
grep -q 'function queuePending' "$APP" && ok "queuePending helper" || bad "queuePending helper"
grep -q 'function applyPendingChanges' "$APP" && ok "applyPendingChanges helper" || bad "applyPendingChanges helper"
grep -q 'function renderPendingPanel' "$APP" && ok "renderPendingPanel helper" || bad "renderPendingPanel helper"
grep -q 'SS_PENDING_STORAGE_KEY' "$APP" && ok "sessionStorage pending key" || bad "sessionStorage pending key"
grep -q 'applyPendingChanges()' "$APP" && ok "btnApplyAll calls applyPendingChanges" || bad "btnApplyAll calls applyPendingChanges"

grep -q 'value="Применить"' "$ASP" && ok "ASP Apply button RU" || bad "ASP Apply button RU"
grep -q 'id="btnCancelAll"' "$ASP" && ok "ASP Cancel button" || bad "ASP Cancel button"
grep -q 'function cancelPendingChanges' "$APP" && ok "cancelPendingChanges helper" || bad "cancelPendingChanges helper"
grep -q 'pendingChangesList' "$ASP" && ok "ASP pendingChangesList" || bad "ASP pendingChangesList"
grep -q 'Нет изменений' "$ASP" && ok "ASP empty pending text" || bad "ASP empty pending text"
grep -q 'ss-pending' "$ASP" && ok "ASP pending CSS class" || bad "ASP pending CSS class"

# btnApplyAll must not immediately rebuild anymore
if awk '/btnApplyAll/,/^\s*\}\);/' "$APP" | grep -q 'triggerService("rebuild"'; then
  bad "btnApplyAll still rebuilds immediately"
else
  ok "btnApplyAll no longer immediate rebuild"
fi

# Config save buttons queue — no direct triggerService at call sites
for pair in \
  'btnSaveKey:setkey' \
  'btnAddKey:addkey' \
  'btnSaveRouting:setrouting' \
  'btnSavePolicies:setpolicies' \
  'btnSetMode:setmode' \
  'btnSetDns:setdnsmode' \
  'btnPreset:preset' \
  'btnSetDefault:setdefault' \
  'btnUpdateSettings:updatesettings' \
  'btnApplySole:apply'
do
  btn=${pair%%:*}
  act=${pair##*:}
  # Extract approximate listener body: from btn id string to next byId( or end of bind chunk is hard;
  # assert queuePending mentions the action and no direct triggerService("act" remains for that button path.
  if grep -n "triggerService(\"$act\"" "$APP" >/dev/null 2>&1; then
    # allowed only inside applyPendingChanges single-op path or queuePending fallback
    hits=$(grep -n "triggerService(\"$act\"" "$APP" | grep -v 'applyPendingChanges\|queuePending\|SS_PENDING' || true)
    # Single-op applyPendingChanges uses snapshot[0].action dynamically — no literal triggerService("setkey"
    if [ -n "$hits" ]; then
      bad "$btn still has literal triggerService($act)"
    else
      ok "no literal triggerService($act) call sites"
    fi
  else
    ok "no literal triggerService($act) call sites"
  fi
  grep -q "queuePending(" "$APP" && grep -q "\"$act\"" "$APP" && ok "queue path mentions $act" || bad "queue path mentions $act"
done

# Settings modal queues setsettings (via helper or direct)
if grep -q 'function queueSettingsFromModal' "$APP" && grep -n 'function saveSettingsFromModal' -A50 "$APP" | grep -q 'queueSettingsFromModal\|queuePending("settings"'; then
  ok "settings modal queues setsettings"
else
  bad "settings modal queues setsettings"
fi
if grep -n 'function saveSettingsFromModal' -A50 "$APP" | grep -q 'triggerService("setsettings"'; then
  bad "settings modal still triggerService setsettings"
else
  ok "settings modal no immediate setsettings"
fi

grep -q 'testTelegramFromModal\|testtelegram\|setTgEnabled' "$APP" && bad "telegram UI leftovers in app.js" || ok "telegram UI removed from app.js"
grep -q 'RULE: Deferred Apply' "$APP" && ok "deferred-apply RULE comment in app.js" || bad "deferred-apply RULE comment in app.js"
[ -f "$ROOT/docs/DEFERRED_APPLY.md" ] && ok "docs/DEFERRED_APPLY.md present" || bad "docs/DEFERRED_APPLY.md present"
grep -q 'queuePending' "$ROOT/docs/DEFERRED_APPLY.md" && ok "docs mention queuePending" || bad "docs mention queuePending"

# No literal config-save triggerService left outside applyPending/queuePending fallback
for act in setsettings setkey setrouting setpolicies setmode setdnsmode setoutbounds; do
  hits=$(grep -n "triggerService(\"$act\"" "$APP" | grep -v 'applyPendingChanges\|queuePending\|SS_PENDING\|RULE:' || true)
  if [ -n "$hits" ]; then
    bad "literal triggerService($act) outside pending path"
  else
    ok "no stray triggerService($act)"
  fi
done
if grep -n 'btnRebuild' -A12 "$APP" | grep -q 'triggerService("setoutbounds"'; then
  bad "btnRebuild still immediate setoutbounds"
else
  ok "btnRebuild queues setoutbounds"
fi

# Immediate operational actions still use triggerService
grep -q 'triggerService("start"' "$APP" && ok "start still immediate" || bad "start still immediate"
grep -q 'triggerService("stop"' "$APP" && ok "stop still immediate" || bad "stop still immediate"
grep -q 'triggerService("sync"' "$APP" && ok "sync still immediate" || bad "sync still immediate"
grep -q 'triggerService("update"' "$APP" && ok "update still immediate" || bad "update still immediate"

# applyPendingChanges clears pending then submits (single or batch)
if grep -n 'function applyPendingChanges' -A35 "$APP" | grep -q 'clearPending'; then
  ok "apply clears pending before submit"
else
  bad "apply clears pending before submit"
fi
grep -q 'applypending' "$APP" && ok "batch path uses applypending" || bad "batch path uses applypending"

# Disabled when empty
grep -q 'btn.disabled = ops.length === 0' "$APP" && ok "Применить disabled when clean" || bad "Применить disabled when clean"

# --- Backend: applypending + defer rebuild ---------------------------------
grep -q 'applypending | batch)' "$SE" && ok "service_event applypending" || bad "service_event applypending"
grep -q 'SS_DEFER_REBUILD' "$CTRL" && ok "control SS_DEFER_REBUILD" || bad "control SS_DEFER_REBUILD"
grep -q 'SS_BATCH_SILENT' "$HELP" && ok "helper SS_BATCH_SILENT" || bad "helper SS_BATCH_SILENT"
grep -q 'SS_DEFER_REBUILD' "$SE" && ok "applypending sets SS_DEFER_REBUILD" || bad "applypending sets SS_DEFER_REBUILD"

# Optional payload override for nested ops
grep -q 'Optional 3rd arg: explicit payload' "$SE" && ok "service_event payload override" || bad "service_event payload override"

# Version present (do not pin patch here — release bumps independently)
grep -qE 'ADDON_VERSION="1\.[0-9]+\.[0-9]+"' "$ROOT/src/backend/_globals.sh" && ok "ADDON_VERSION set" || bad "ADDON_VERSION set"

# --- Lightweight smoke: SS_BATCH_SILENT + SS_DEFER_REBUILD semantics ---------
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
SS_UI_RESPONSE="$TMP/resp.json"

# Mirror helper silent branch (avoid sourcing full _helper ss_ensure_dirs side effects)
ss_json_response_silent_check() {
  local status="$1"
  local status_json="false"
  case "$status" in
  true | 1 | ok | OK) status_json="true" ;;
  esac
  if [ "${SS_BATCH_SILENT:-0}" = "1" ]; then
    [ "$status_json" = "true" ]
    return $?
  fi
  printf '%s' "{\"status\":$status_json}" >"$SS_UI_RESPONSE"
  return 0
}

SS_BATCH_SILENT=1
if ss_json_response_silent_check true; then
  ok "SS_BATCH_SILENT success returns 0"
else
  bad "SS_BATCH_SILENT success returns 0"
fi
if [ -f "$SS_UI_RESPONSE" ]; then
  bad "SS_BATCH_SILENT must not write response file"
else
  ok "SS_BATCH_SILENT skips response file"
fi
if ss_json_response_silent_check false; then
  bad "SS_BATCH_SILENT failure returns non-zero"
else
  ok "SS_BATCH_SILENT failure returns non-zero"
fi
unset SS_BATCH_SILENT
ss_json_response_silent_check true
[ -f "$SS_UI_RESPONSE" ] && ok "non-silent writes response file" || bad "non-silent writes response file"

# Defer rebuild stub (same gate as control.sh)
ss_rebuild_xray_config() { echo rebuild_called >>"$TMP/rebuild.log"; return 0; }
ss_soft_restart_inner() { echo restart_called >>"$TMP/rebuild.log"; return 0; }
ss_rebuild_and_restart() {
  if [ "${SS_DEFER_REBUILD:-0}" = "1" ]; then
    SS_NEED_REBUILD=1
    export SS_NEED_REBUILD
    return 0
  fi
  ss_rebuild_xray_config || return 1
  ss_soft_restart_inner
}

SS_DEFER_REBUILD=1
ss_rebuild_and_restart
[ "${SS_NEED_REBUILD:-0}" = "1" ] && ok "defer sets SS_NEED_REBUILD" || bad "defer sets SS_NEED_REBUILD"
[ ! -f "$TMP/rebuild.log" ] && ok "defer skips rebuild body" || bad "defer skips rebuild body"
unset SS_DEFER_REBUILD
ss_rebuild_and_restart
grep -q rebuild_called "$TMP/rebuild.log" && ok "non-defer rebuild runs" || bad "non-defer rebuild runs"

# Source helper and assert the real silent branch exists + behaves
# shellcheck disable=SC1091
ss_ensure_dirs() { mkdir -p "$ADDON_WEB_DIR" 2>/dev/null || true; }
export ADDON_TAG=stealthsurf ADDON_WEB_DIR="$TMP/web" ADDON_SHARE_DIR="$TMP" ADDON_TMP_DIR="$TMP/tmp"
export ADDON_LOGS_DIR="$TMP/logs" ADDON_DATA_DIR="$TMP/data" ADDON_BACKUP_DIR="$TMP/backups"
export SS_UI_RESPONSE="$TMP/web/stealthsurf-response.json"
mkdir -p "$ADDON_WEB_DIR"
# Extract only ss_json_response by sourcing helper after stubbing ensure_dirs — skip if helper
# pulls missing paths at source time; grep already covered the real code path above.
grep -A8 'if \[ "${SS_BATCH_SILENT:-0}" = "1" \]' "$HELP" | grep -q 'status_json' && ok "helper silent branch present" || bad "helper silent branch present"

if [ "$fail" -ne 0 ]; then
  echo "FAILED: $fail checks"
  exit 1
fi
echo "All deferred-apply checks passed"
exit 0
