#!/bin/sh
# Unit tests for API-key account balance helpers (no live router / StealthSurf API).
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export ADDON_TAG=stealthsurf
export ADDON_VERSION=1.0.29
export ADDON_TITLE=StealthSurf
export ADDON_SHARE_DIR="$TMP"
export ADDON_WEB_DIR="$TMP/web"
export ADDON_TMP_DIR="$TMP/tmp"
export ADDON_LOGS_DIR="$TMP/logs"
export ADDON_DATA_DIR="$TMP/data"
export ADDON_BACKUP_DIR="$TMP/backups"
export SS_CONF_FILE="$TMP/stealthsurf.conf"
export SS_CACHE_KEYS="$TMP/api_keys.json"
export SS_CACHE_SUBSCRIPTIONS="$TMP/subscriptions.json"
export SS_CACHE_CONFIGS="$TMP/configs.json"
export SS_CACHE_PROFILE="$TMP/profile.json"
export SS_CACHE_BALANCES="$TMP/balances.json"
export SS_CACHE_LOCATIONS="$TMP/locations.json"
export SS_ENDPOINTS_FILE="$TMP/endpoints.json"
export SS_POLICIES_FILE="$TMP/policies.json"
export SS_ROUTING_FILE="$TMP/routing.json"
export SS_OUTBOUNDS_FILE="$TMP/outbounds.json"
export SS_STATE_FILE="$TMP/state.json"
export SS_UI_RESPONSE="$TMP/web/stealthsurf-response.json"
export SS_API_KEY="" SS_API_KEYS="" SS_API_BASE="https://api.stealthsurf.net"
export SS_ACTIVE_CONFIG_ID="" SS_DEFAULT_OUTBOUND="" SS_ENABLED_OUTBOUNDS=""

mkdir -p "$ADDON_WEB_DIR" "$ADDON_TMP_DIR" "$ADDON_LOGS_DIR" "$ADDON_DATA_DIR" "$ADDON_BACKUP_DIR"
echo '[]' >"$SS_CACHE_KEYS"
echo '[]' >"$SS_CACHE_SUBSCRIPTIONS"
echo '[]' >"$SS_CACHE_CONFIGS"
echo '[]' >"$SS_ENDPOINTS_FILE"
echo '{"rules":[]}' >"$SS_POLICIES_FILE"
echo '{"rules":[]}' >"$SS_ROUTING_FILE"
echo '{"enabled":[],"default":""}' >"$SS_OUTBOUNDS_FILE"

ss_info() { :; }
ss_ok() { :; }
ss_warn() { :; }
ss_error() { echo "ERR $*" >&2; }
ss_activity() { :; }
ss_log() { :; }
ss_save_conf() { :; }

# shellcheck disable=SC1091
. "$ROOT/src/backend/_helper.sh"
ss_ensure_dirs() {
  mkdir -p "$ADDON_SHARE_DIR" "$ADDON_WEB_DIR" "$ADDON_TMP_DIR" "$ADDON_BACKUP_DIR" "$ADDON_LOGS_DIR" "$ADDON_DATA_DIR"
  [ -f "$SS_CACHE_KEYS" ] || echo '[]' >"$SS_CACHE_KEYS"
  [ -f "$SS_CACHE_BALANCES" ] || echo '{"fetched_at":0,"keys":[],"total_balance":0,"total_referral":0,"currency":"RUB"}' >"$SS_CACHE_BALANCES"
}
# shellcheck disable=SC1091
. "$ROOT/src/backend/api_client.sh"

fail=0
ok() { echo "OK  $1"; }
bad() { echo "FAIL $1"; fail=$((fail + 1)); }

masked=$(ss_mask_email "user@example.com")
echo "$masked" | grep -q '@example.com' && ok "mask keeps domain" || bad "mask keeps domain ($masked)"
echo "$masked" | grep -qv '^user@' && ok "mask hides local-part" || bad "mask hides local-part ($masked)"

SS_API_KEY='stlth_deadbeef_0123456789abcdef01234567'
ss_api_keys_store_add "$SS_API_KEY" "home"
meta=$(ss_api_key_meta "$SS_API_KEY")
echo "$meta" | jq -e '.label == "home"' >/dev/null && ok "meta label" || bad "meta label"
echo "$meta" | jq -e '.key_fp == "deadbeef"' >/dev/null && ok "meta key_fp" || bad "meta key_fp"
echo "$meta" | jq -e '.key_tail | length == 8' >/dev/null && ok "meta key_tail" || bad "meta key_tail"
echo "$meta" | grep -q 'stlth_deadbeef_0123456789abcdef01234567' && bad "meta must not contain full key" || ok "meta omits full key"

ss_api_with_key() {
  local key="$1" method="$2" path="$3"
  case "$path" in
  /profile)
    case "$key" in
    *deadbeef*)
      printf '%s' '{"status":true,"statusCode":200,"data":{"id":101,"email":"alice@example.com","balance":500,"referral_balance":25}}'
      return 0
      ;;
    *cafebabe*)
      printf '%s' '{"status":true,"statusCode":200,"data":{"id":202,"email":"bob@example.com","balance":120.5,"referral_balance":0}}'
      return 0
      ;;
    *badkeyxx*)
      printf '%s' '{"status":false,"statusCode":401,"message":"access denied"}'
      return 1
      ;;
    esac
    ;;
  esac
  printf '%s' '{"status":false,"message":"unexpected"}'
  return 1
}

KEY2='stlth_cafebabe_fedcba9876543210fedcba98'
ss_api_keys_store_add "$KEY2" "work"
SS_API_KEYS="$KEY2"

out=$(ss_api_fetch_balances 1)
echo "$out" | jq -e '.ok == 2' >/dev/null && ok "fetch ok count 2" || bad "fetch ok count (got $(echo "$out" | jq -c '{ok,fail}'))"
echo "$out" | jq -e '.fail == 0' >/dev/null && ok "fetch fail 0" || bad "fetch fail 0"
echo "$out" | jq -e '.total_balance == 620.5' >/dev/null && ok "total_balance sum" || bad "total_balance sum ($(echo "$out" | jq .total_balance))"
echo "$out" | jq -e '.total_referral == 25' >/dev/null && ok "total_referral sum" || bad "total_referral"
echo "$out" | jq -e '[.keys[].ok] | all' >/dev/null && ok "all keys ok" || bad "all keys ok"
echo "$out" | grep -Eq 'stlth_(deadbeef|cafebabe)_' && bad "balances cache leaked full key" || ok "balances cache has no full keys"
[ -L "$ADDON_WEB_DIR/balances.json" ] || [ -f "$ADDON_WEB_DIR/balances.json" ] && ok "web balances.json published" || bad "web balances.json published"

ss_api_with_key() { printf '%s' '{"status":false,"message":"should not call"}'; return 1; }
cached=$(ss_api_fetch_balances 0)
echo "$cached" | jq -e '.ok == 2 and .total_balance == 620.5' >/dev/null && ok "soft cache reused" || bad "soft cache reused"

ss_api_with_key() {
  local key="$1" path="$3"
  case "$path" in
  /profile)
    case "$key" in
    *deadbeef*)
      printf '%s' '{"status":true,"data":{"id":101,"email":"a@b.c","balance":10,"referral_balance":0}}'
      return 0
      ;;
    *)
      printf '%s' '{"status":false,"message":"access denied"}'
      return 1
      ;;
    esac
    ;;
  esac
  return 1
}
forced=$(ss_api_fetch_balances 1) || true
echo "$forced" | jq -e '.ok == 1 and .fail == 1' >/dev/null && ok "partial success ok/fail" || bad "partial success ($(echo "$forced" | jq -c '{ok,fail}'))"
echo "$forced" | jq -e '.keys | map(select(.ok==false)) | length == 1' >/dev/null && ok "error row present" || bad "error row present"
echo "$forced" | jq -e '[.keys[] | select(.ok==false) | .error] | length == 1' >/dev/null && ok "error message set" || bad "error message set"

SS_API_KEY="" SS_API_KEYS=""
echo '[]' >"$SS_CACHE_KEYS"
empty=$(ss_api_fetch_balances 1)
echo "$empty" | jq -e '.keys | length == 0' >/dev/null && ok "empty keys list" || bad "empty keys list"

grep -q 'balances | refreshbalances | balance)' "$ROOT/src/backend/service_event.sh" && ok "service-event balances action" || bad "service-event balances action"
grep -q 'ss_api_fetch_balances' "$ROOT/src/backend/service_event.sh" && ok "service-event calls fetch" || bad "service-event calls fetch"
grep -q 'balances.json' "$ROOT/src/backend/mount.sh" && ok "mount links balances.json" || bad "mount links balances.json"
grep -q 'id="sumBalance"' "$ROOT/src/ui/index.asp" && ok "UI sumBalance" || bad "UI sumBalance"
grep -q 'id="btnRefreshBalance"' "$ROOT/src/ui/index.asp" && ok "UI refresh button" || bad "UI refresh button"
grep -q 'id="balanceTable"' "$ROOT/src/ui/index.asp" && ok "UI balance table" || bad "UI balance table"
grep -q 'function renderBalances' "$ROOT/src/ui/app.js" && ok "app renderBalances" || bad "app renderBalances"
grep -q 'requestBalancesRefresh' "$ROOT/src/ui/app.js" && ok "app requestBalancesRefresh" || bad "app requestBalancesRefresh"
grep -q 'balances.json' "$ROOT/src/ui/app.js" && ok "app loads balances.json" || bad "app loads balances.json"
grep -q 'refreshBalancesFromApi' "$ROOT/src/ui/app.js" && ok "app refreshBalancesFromApi" || bad "app refreshBalancesFromApi"
if grep -nE 'triggerService\("balances"|triggerService\("refreshbalances"|triggerService\("balance"' "$ROOT/src/ui/app.js" >/dev/null 2>&1; then
  bad "UI still form-submits balances via triggerService"
else
  ok "UI does not form-submit balances"
fi
grep -q 'balances | balance | bal)' "$ROOT/src/backend/stealthsurf.sh" && ok "CLI bal command" || bad "CLI bal command"
grep -q 'SS_CACHE_BALANCES' "$ROOT/src/backend/_globals.sh" && ok "globals SS_CACHE_BALANCES" || bad "globals SS_CACHE_BALANCES"

if [ "$fail" -ne 0 ]; then
  echo "FAILED: $fail"
  exit 1
fi
echo "ALL PASS"
exit 0
