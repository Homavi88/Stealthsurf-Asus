#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export ADDON_TAG=stealthsurf
export ADDON_VERSION=1.0.33
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
export SS_TG_PIDFILE="$TMP/telegram.pid"
export SS_TG_OFFSET_FILE="$TMP/telegram.offset"
export SS_TG_LOG="$TMP/logs/telegram.log"
export SS_API_KEY="" SS_API_KEYS="" SS_API_BASE="https://api.stealthsurf.net"
export SS_ACTIVE_CONFIG_ID="" SS_DEFAULT_OUTBOUND="ss-101" SS_ENABLED_OUTBOUNDS="101"
export SS_SOCKS_PORT=10808 SS_HTTP_PORT=10809 SS_TPROXY_PORT=10810 SS_REDIRECT_PORT=10811 SS_DNS_PORT=5353
export SS_MODE=proxy SS_DNS_MODE=OFF SS_PROXY_MODE=proxy
export SS_FALLBACK_OUTBOUND=direct SS_XRAY_ACCESS_LOG=0
export GEODATA_BASE="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download"
export SS_TG_ENABLED=0 SS_TG_BOT_TOKEN="" SS_TG_CHAT_IDS=""
mkdir -p "$ADDON_WEB_DIR" "$ADDON_TMP_DIR" "$ADDON_LOGS_DIR" "$ADDON_DATA_DIR" "$ADDON_BACKUP_DIR"
echo '{"enabled":[101],"default":"ss-101"}' >"$SS_OUTBOUNDS_FILE"
echo '{"rules":[]}' >"$SS_POLICIES_FILE"
echo '{"rules":[],"default_outbound":"ss-101"}' >"$SS_ROUTING_FILE"
echo '[]' >"$SS_CACHE_KEYS"
echo '[]' >"$SS_CACHE_SUBSCRIPTIONS"
printf '%s\n' '[{"id":101,"protocol":"vless","title":"NL-1","location_id":1,"expires_at":null,"is_online":true},{"id":205,"protocol":"hysteria2","title":"US-2","location_id":2,"expires_at":null,"is_online":false}]' >"$SS_CACHE_CONFIGS"
echo '[]' >"$SS_ENDPOINTS_FILE"

ss_info() { :; }
ss_ok() { :; }
ss_warn() { :; }
ss_error() { echo "ERR $*" >&2; }
ss_activity() { :; }
ss_log() { :; }
ss_rebuild_and_restart() { return 0; }
ss_xray_running() { return 1; }
ss_start() { return 0; }
ss_stop() { return 0; }
ss_restart() { return 0; }
ss_with_lock() { shift; "$@"; }

# shellcheck disable=SC1091
. "$ROOT/src/backend/_helper.sh"
ss_ensure_dirs() { mkdir -p "$ADDON_SHARE_DIR" "$ADDON_WEB_DIR" "$ADDON_TMP_DIR" "$ADDON_BACKUP_DIR" "$ADDON_LOGS_DIR" "$ADDON_DATA_DIR"; }
# shellcheck disable=SC1091
. "$ROOT/src/backend/routing.sh"
# shellcheck disable=SC1091
. "$ROOT/src/backend/settings.sh"
# shellcheck disable=SC1091
. "$ROOT/src/backend/telegram.sh"

fail=0
assert_eq() {
  if [ "$1" = "$2" ]; then
    echo "OK  $3"
  else
    echo "FAIL $3 (got='$1' want='$2')"
    fail=$((fail + 1))
  fi
}
assert_has() {
  if printf '%s' "$1" | grep -q "$2"; then
    echo "OK  $3"
  else
    echo "FAIL $3 (missing '$2' in: $1)"
    fail=$((fail + 1))
  fi
}

# --- token mask / chat ids ---
assert_eq "$(ss_telegram_token_hint "123456:ABCDEFGH")" "...EFGH" "token hint last4"
assert_eq "$(ss_telegram_mask_token "********")" "" "mask keep empty previous"
SS_TG_BOT_TOKEN="old-token-value"
assert_eq "$(ss_telegram_mask_token "********")" "old-token-value" "mask keep previous"
assert_eq "$(ss_telegram_mask_token "999:NEWTOKEN")" "999:NEWTOKEN" "mask accept new"
assert_eq "$(ss_telegram_normalize_chat_ids "1, 2;3")" "1 2 3" "normalize chat ids"

SS_TG_CHAT_IDS="111 222"
ss_telegram_chat_allowed 111 && echo "OK  chat allowed" || {
  echo "FAIL chat allowed"
  fail=$((fail + 1))
}
ss_telegram_chat_allowed 999 && {
  echo "FAIL chat should deny"
  fail=$((fail + 1))
} || echo "OK  chat denied"

# --- outbound normalize ---
assert_eq "$(ss_telegram_normalize_outbound 101)" "ss-101" "outbound id→tag"
assert_eq "$(ss_telegram_normalize_outbound ss-205)" "ss-205" "outbound tag passthrough"
assert_eq "$(ss_telegram_normalize_outbound direct)" "direct" "outbound direct"

# --- list / rules text ---
assert_has "$(ss_telegram_list_text)" "NL-1" "list shows title"
assert_has "$(ss_telegram_list_text)" "\\[ON\\]" "list marks enabled"
assert_has "$(ss_telegram_rules_text)" "Default:" "rules header"

# --- add rule ---
out=$(ss_telegram_add_rule domain youtube.com 101 yt 2>&1) || true
assert_has "$out" "youtube.com" "ruleadd reply"
n=$(jq '.rules|length' "$SS_ROUTING_FILE")
assert_eq "$n" "1" "one rule stored"
ob=$(jq -r '.rules[0].outbound' "$SS_ROUTING_FILE")
assert_eq "$ob" "ss-101" "rule outbound tag"

# reject disabled outbound
set +e
out=$(ss_telegram_add_rule domain netflix.com 205 nf 2>&1)
rc=$?
set -e
assert_eq "$rc" "1" "reject disabled outbound"
assert_has "$out" "не включён" "reject message"

# --- settings apply telegram block ---
# Note: $(ss_settings_apply) runs in a subshell — check JSON + conf file, not parent env.
applied=$(ss_settings_apply '{"telegram":{"enabled":true,"bot_token":"111:AAAABBBBCCCC","chat_ids":"42, 99"}}')
assert_eq "$(printf '%s' "$applied" | jq -r '.telegram.enabled')" "true" "settings tg enabled"
assert_eq "$(printf '%s' "$applied" | jq -r '.telegram.bot_token')" "********" "settings mask token"
assert_eq "$(printf '%s' "$applied" | jq -r '.telegram.bot_token_set')" "true" "settings token set"
assert_eq "$(printf '%s' "$applied" | jq -r '.telegram.chat_ids')" "42 99" "settings chat ids"
grep -q "SS_TG_BOT_TOKEN='111:AAAABBBBCCCC'" "$SS_CONF_FILE" && echo "OK  conf token kept" || {
  echo "FAIL conf token kept"
  fail=$((fail + 1))
}
grep -q "SS_TG_ENABLED='1'" "$SS_CONF_FILE" && echo "OK  conf tg enabled" || {
  echo "FAIL conf tg enabled"
  fail=$((fail + 1))
}

# keep token when UI sends mask (reload conf into this shell first)
# shellcheck disable=SC1090
. "$SS_CONF_FILE"
applied=$(ss_settings_apply '{"telegram":{"enabled":true,"bot_token":"********","chat_ids":"42"}}')
grep -q "SS_TG_BOT_TOKEN='111:AAAABBBBCCCC'" "$SS_CONF_FILE" && echo "OK  keep token on mask save" || {
  echo "FAIL keep token on mask save"
  fail=$((fail + 1))
}
assert_eq "$(printf '%s' "$applied" | jq -r '.telegram.chat_ids')" "42" "chat ids update alone"

# disable without clearing token
applied=$(ss_settings_apply '{"telegram":{"enabled":false}}')
assert_eq "$(printf '%s' "$applied" | jq -r '.telegram.enabled')" "false" "disable tg"
grep -q "SS_TG_ENABLED='0'" "$SS_CONF_FILE" && echo "OK  SS_TG_ENABLED 0" || {
  echo "FAIL SS_TG_ENABLED 0"
  fail=$((fail + 1))
}
grep -q "SS_TG_BOT_TOKEN='111:AAAABBBBCCCC'" "$SS_CONF_FILE" && echo "OK  token kept when disabled" || {
  echo "FAIL token kept when disabled"
  fail=$((fail + 1))
}

# reject enable without token (run in-process so return code is visible)
SS_TG_BOT_TOKEN=""
SS_TG_ENABLED=0
set +e
ss_settings_apply '{"telegram":{"enabled":true,"bot_token":"","chat_ids":"1"}}' >/dev/null 2>&1
rc=$?
set -e
assert_eq "$rc" "1" "reject enable without token"

# --- command parsing via process_updates (mocked send) ---
SS_TG_ENABLED=1
SS_TG_BOT_TOKEN="111:TEST"
SS_TG_CHAT_IDS="777"
SENT=""
ss_telegram_send() { SENT="$2"; }
ss_telegram_process_updates_json '{"ok":true,"result":[{"update_id":5,"message":{"chat":{"id":777},"text":"/status"}}]}'
assert_has "$SENT" "StealthSurf" "status reply"
assert_eq "$(cat "$SS_TG_OFFSET_FILE")" "6" "offset advanced"

SENT=""
ss_telegram_process_updates_json '{"ok":true,"result":[{"update_id":6,"message":{"chat":{"id":999},"text":"/on"}}]}'
assert_has "$SENT" "Доступ запрещён" "deny unknown chat"
assert_has "$SENT" "999" "deny shows chat id"

SENT=""
ss_telegram_process_updates_json '{"ok":true,"result":[{"update_id":7,"message":{"chat":{"id":888},"text":"/whoami"}}]}'
assert_has "$SENT" "888" "whoami without whitelist"

# --- UI markers ---
grep -q 'setTgEnabled' "$ROOT/src/ui/index.asp" && echo "OK  ASP telegram block" || {
  echo "FAIL ASP telegram block"
  fail=$((fail + 1))
}
grep -q 'telegram:' "$ROOT/src/ui/app.js" && echo "OK  UI telegram payload" || {
  echo "FAIL UI telegram payload"
  fail=$((fail + 1))
}
grep -q 'import ./telegram.sh' "$ROOT/src/backend/stealthsurf.sh" && echo "OK  telegram import" || {
  echo "FAIL telegram import"
  fail=$((fail + 1))
}

[ "$fail" -eq 0 ] && echo "ALL PASS" || {
  echo "FAILED $fail"
  exit 1
}
