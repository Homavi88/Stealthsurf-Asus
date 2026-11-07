#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export ADDON_TAG=stealthsurf
export ADDON_VERSION=1.0.19
export ADDON_SHARE_DIR="$TMP"
export ADDON_WEB_DIR="$TMP/web"
export ADDON_TMP_DIR="$TMP/tmp"
export ADDON_LOGS_DIR="$TMP/logs"
export ADDON_DATA_DIR="$TMP/data"
export ADDON_BACKUP_DIR="$TMP/backups"
export SS_CONF_FILE="$TMP/stealthsurf.conf"
export SS_SETTINGS_FILE="$TMP/settings.json"
export SS_OUTBOUNDS_FILE="$TMP/outbounds.json"
export SS_POLICIES_FILE="$TMP/policies.json"
export SS_ROUTING_FILE="$TMP/routing.json"
export SS_CACHE_KEYS="$TMP/api_keys.json"
export SS_CACHE_SUBSCRIPTIONS="$TMP/subscriptions.json"
export SS_CACHE_CONFIGS="$TMP/configs.json"
export SS_ENDPOINTS_FILE="$TMP/endpoints.json"
export SS_API_KEY="" SS_API_KEYS="" SS_API_BASE="https://api.stealthsurf.net"
export SS_ACTIVE_CONFIG_ID="" SS_DEFAULT_OUTBOUND="" SS_ENABLED_OUTBOUNDS=""
export SS_SOCKS_PORT=10808 SS_HTTP_PORT=10809 SS_TPROXY_PORT=10810 SS_REDIRECT_PORT=10811 SS_DNS_PORT=5353
export SS_MODE=proxy SS_DNS_MODE=OFF SS_PROXY_MODE=proxy
export SS_FALLBACK_OUTBOUND=direct SS_XRAY_ACCESS_LOG=0
export GEODATA_BASE="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download"
mkdir -p "$ADDON_WEB_DIR" "$ADDON_TMP_DIR" "$ADDON_LOGS_DIR" "$ADDON_DATA_DIR" "$ADDON_BACKUP_DIR"
echo '{"enabled":[],"default":""}' >"$SS_OUTBOUNDS_FILE"
echo '{"rules":[]}' >"$SS_POLICIES_FILE"
echo '{"rules":[]}' >"$SS_ROUTING_FILE"
echo '[]' >"$SS_CACHE_KEYS"
echo '[]' >"$SS_CACHE_SUBSCRIPTIONS"
echo '[]' >"$SS_CACHE_CONFIGS"
echo '[]' >"$SS_ENDPOINTS_FILE"

ss_info() { :; }
ss_ok() { :; }
ss_warn() { :; }
ss_error() { echo "ERR $*" >&2; }
ss_activity() { :; }
ss_log() { :; }

# shellcheck disable=SC1091
. "$ROOT/src/backend/_helper.sh"
# Prefer local dirs only (avoid /opt writes in CI)
ss_ensure_dirs() { mkdir -p "$ADDON_SHARE_DIR" "$ADDON_WEB_DIR" "$ADDON_TMP_DIR" "$ADDON_BACKUP_DIR" "$ADDON_LOGS_DIR" "$ADDON_DATA_DIR"; }
# shellcheck disable=SC1091
. "$ROOT/src/backend/settings.sh"

fail=0
assert_eq() {
  if [ "$1" = "$2" ]; then
    echo "OK  $3"
  else
    echo "FAIL $3 (got='$1' want='$2')"
    fail=$((fail + 1))
  fi
}

json=$(ss_settings_json)
assert_eq "$(printf '%s' "$json" | jq -r '.auto_start')" "true" "default auto_start"
assert_eq "$(printf '%s' "$json" | jq -r '.reboot_schedule')" "off" "default reboot off"
assert_eq "$(printf '%s' "$json" | jq -r '.geodata_auto')" "false" "default geodata auto off"

applied=$(ss_settings_apply '{"auto_start":false,"watchdog":true,"auto_backup":false,"backup_keep":7,"startup_delay":12,"reboot_schedule":"weekly","geodata_auto":true,"geodata_schedule":"daily","geodata_base":"https://example.com/geo"}')
assert_eq "$(printf '%s' "$applied" | jq -r '.auto_start')" "false" "apply auto_start false"
assert_eq "$(printf '%s' "$applied" | jq -r '.backup_keep')" "7" "apply backup_keep"
assert_eq "$(printf '%s' "$applied" | jq -r '.reboot_schedule')" "weekly" "apply reboot weekly"
assert_eq "$(printf '%s' "$applied" | jq -r '.geodata_auto')" "true" "apply geodata auto"
assert_eq "$(printf '%s' "$applied" | jq -r '.geodata_base')" "https://example.com/geo" "apply geodata base"
assert_eq "$(printf '%s' "$applied" | jq -r '.auto_start')" "false" "json auto_start false"
assert_eq "$(printf '%s' "$applied" | jq -r '.geodata_schedule')" "daily" "json geodata schedule"

grep -q "SS_AUTO_START='0'" "$SS_CONF_FILE" && echo "OK  conf auto_start" || {
  echo "FAIL conf auto_start"
  fail=$((fail + 1))
}
grep -q "SS_REBOOT_SCHEDULE='weekly'" "$SS_CONF_FILE" && echo "OK  conf reboot" || {
  echo "FAIL conf reboot"
  fail=$((fail + 1))
}
grep -q "SS_GEODATA_BASE='https://example.com/geo'" "$SS_CONF_FILE" && echo "OK  conf geodata base" || {
  echo "FAIL conf geodata base"
  fail=$((fail + 1))
}
grep -q "SS_GEODATA_AUTO='1'" "$SS_CONF_FILE" && echo "OK  conf geodata auto" || {
  echo "FAIL conf geodata auto"
  fail=$((fail + 1))
}
[ -f "$SS_SETTINGS_FILE" ] && echo "OK  settings.json written" || {
  echo "FAIL settings.json missing"
  fail=$((fail + 1))
}

# Reload conf into this shell (apply runs vars in-process already when not captured)
# shellcheck disable=SC1090
. "$SS_CONF_FILE"
assert_eq "$(ss_settings_reboot_cron_expr)" "15 4 * * 0" "weekly reboot cron"
assert_eq "$(ss_settings_geodata_cron_expr)" "30 5 * * *" "daily geodata cron"

SS_REBOOT_SCHEDULE=custom
SS_REBOOT_CRON="0 3 * * 1"
assert_eq "$(ss_settings_reboot_cron_expr)" "0 3 * * 1" "custom reboot cron"

set +e
ss_settings_apply '{"reboot_schedule":"custom","reboot_cron":"bad"}' >/dev/null 2>&1
rej=$?
set -e
if [ "$rej" -eq 0 ]; then
  echo "FAIL custom cron should reject short expr"
  fail=$((fail + 1))
else
  echo "OK  reject short custom cron"
fi

grep -q 'settingsModal' "$ROOT/src/ui/index.asp" && echo "OK  ASP settings modal" || {
  echo "FAIL ASP settings modal"
  fail=$((fail + 1))
}
grep -q 'openSettingsModal' "$ROOT/src/ui/app.js" && echo "OK  UI openSettingsModal" || {
  echo "FAIL UI openSettingsModal"
  fail=$((fail + 1))
}
grep -q 'setsettings' "$ROOT/src/backend/service_event.sh" && echo "OK  service setsettings" || {
  echo "FAIL service setsettings"
  fail=$((fail + 1))
}
grep -q 'import ./settings.sh' "$ROOT/src/backend/stealthsurf.sh" && echo "OK  settings import" || {
  echo "FAIL settings import"
  fail=$((fail + 1))
}
grep -q 'import ./telegram.sh' "$ROOT/src/backend/stealthsurf.sh" && {
  echo "FAIL telegram import still present"
  fail=$((fail + 1))
} || echo "OK  telegram import removed"
grep -q 'setTgEnabled\|Telegram-бот' "$ROOT/src/ui/index.asp" && {
  echo "FAIL ASP telegram settings still present"
  fail=$((fail + 1))
} || echo "OK  ASP telegram settings removed"
grep -q '08-settings-modal.png' "$ROOT/tools/capture-ui-screenshots.mjs" && echo "OK  settings screenshot" || {
  echo "FAIL settings screenshot"
  fail=$((fail + 1))
}

[ "$fail" -eq 0 ] && echo "ALL PASS" || {
  echo "FAILED $fail"
  exit 1
}
