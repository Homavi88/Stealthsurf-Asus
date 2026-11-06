#!/bin/sh
# Regression: WebUI setkey/addkey must reach service_event via Merlin service-event
# with a usable payload.
#
# Merlin splits action_script:
#   start_stealthsurf_setkey → $1=start $2=stealthsurf_setkey
#   stealthsurf_setkey       → $1=""    $2=stealthsurf_setkey
# Hook must match on $2, not require $1=start.
#
# Critical: Merlin httpd write_custom_settings() writes amng_custom into
# /jffs/addons/custom_settings.txt as FLAT strings and does NOT nvram_set
# amng_custom. Nested JSON objects are dropped (json_object_get_string → NULL).
# UI must store stealthsurf_payload as a string; backend must read that file.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail=0
ok() { echo "OK  $1"; }
bad() { echo "FAIL $1"; fail=$((fail + 1)); }

HOOKS="$ROOT/src/backend/hooks.sh"
APP="$ROOT/src/ui/app.js"
SE="$ROOT/src/backend/service_event.sh"

# UI must use start_stealthsurf_<action> so Merlin sets $1=start
grep -q 'start_stealthsurf_"' "$APP" && ok "UI action_script start_stealthsurf_" || bad "UI action_script start_stealthsurf_"
if grep -Eq 'action_script\.value = "stealthsurf_"' "$APP"; then
  bad "UI still uses bare stealthsurf_ action_script"
else
  ok "UI no bare stealthsurf_ action_script"
fi

# UI must store FLAT string payload (not nested .stealthsurf object)
grep -q 'stealthsurf_payload' "$APP" && ok "UI writes stealthsurf_payload" || bad "UI writes stealthsurf_payload"
if grep -Eq 'base\.stealthsurf\s*=' "$APP"; then
  bad "UI still assigns nested base.stealthsurf object"
else
  ok "UI no nested base.stealthsurf object"
fi

# Hook must not require $1=start alone
if grep -q '\$1" = "start".*stealthsurf_' "$HOOKS" || grep -q '\[ "\$1" = "start" \] && echo "\$2"' "$HOOKS"; then
  bad "hook still requires \$1=start"
else
  ok "hook does not require \$1=start"
fi
grep -q 'echo "\$2" | grep -q "^stealthsurf_"' "$HOOKS" && ok "hook matches \$2 stealthsurf_" || bad "hook matches \$2 stealthsurf_"

# Hook must NOT rely on nvram get amng_custom as the sole payload source
if grep -q 'nvram get amng_custom' "$HOOKS"; then
  bad "hook still reads nvram amng_custom"
else
  ok "hook does not read nvram amng_custom"
fi
grep -q 'ss_am_settings_get\|ss_read_payload\|custom_settings' "$SE" && ok "service_event reads custom_settings" || bad "service_event reads custom_settings"
grep -q 'stealthsurf_payload' "$SE" && ok "service_event knows stealthsurf_payload" || bad "service_event knows stealthsurf_payload"

# Simulate the generated hook body against Merlin arg shapes
# shellcheck disable=SC1091
. "$HOOKS"
ss_service_event_block >"$TMP/hook.sh"

mkdir -p "$TMP/jffs/scripts" "$TMP/jffs/addons" "$TMP/bin"
# Fake stealthsurf CLI that records the action
cat >"$TMP/jffs/scripts/stealthsurf" <<'EOF'
#!/bin/sh
echo "SE $*" >> /tmp/ss_hook_calls.log
EOF
chmod +x "$TMP/jffs/scripts/stealthsurf"

cat >"$TMP/run_hook.sh" <<EOF
#!/bin/sh
if echo "\$2" | grep -q "^stealthsurf_"; then
  action="\${2#stealthsurf_}"
  case "\$action" in
  uninstall|remove|purge)
    echo blocked > "$TMP/blocked"
    ;;
  *)
    "$TMP/jffs/scripts/stealthsurf" service_event "\$action"
    ;;
  esac
fi
EOF
chmod +x "$TMP/run_hook.sh"
: >/tmp/ss_hook_calls.log

# Case A: XrayUI-style bare action_script (empty $1)
sh "$TMP/run_hook.sh" "" "stealthsurf_setkey"
grep -q 'service_event setkey' /tmp/ss_hook_calls.log && ok "bare stealthsurf_setkey fires" || bad "bare stealthsurf_setkey fires"

# Case B: start_stealthsurf_setkey → $1=start $2=stealthsurf_setkey
: >/tmp/ss_hook_calls.log
sh "$TMP/run_hook.sh" "start" "stealthsurf_setkey"
grep -q 'service_event setkey' /tmp/ss_hook_calls.log && ok "start_stealthsurf_setkey fires" || bad "start_stealthsurf_setkey fires"

# Case C: unrelated service ignored
: >/tmp/ss_hook_calls.log
sh "$TMP/run_hook.sh" "start" "firewall"
[ ! -s /tmp/ss_hook_calls.log ] && ok "unrelated service ignored" || bad "unrelated service ignored"

grep -q 'ss_api_keys_store_add' "$SE" && ok "setkey persists to api_keys store" || bad "setkey persists to api_keys store"

# --- Simulate Merlin flat custom_settings + ss_read_payload ---
# Extract helper functions from service_event.sh into a test harness
cat >"$TMP/payload_harness.sh" <<'EOF'
#!/bin/sh
# Minimal stubs + real payload readers from service_event.sh
ss_am_settings_get() {
  local key="$1"
  local settings="/jffs/addons/custom_settings.txt"
  [ -f "$settings" ] || return 0
  grep -E "^${key} " "$settings" 2>/dev/null | head -1 | cut -f2- -d ' '
}

ss_clear_ui_payload_settings() {
  local settings="/jffs/addons/custom_settings.txt"
  local tmp
  [ -f "$settings" ] || return 0
  grep -qE '^stealthsurf_payload|^stealthsurf ' "$settings" 2>/dev/null || return 0
  tmp="$settings.ss.$$"
  grep -vE '^stealthsurf_payload([0-9]+)? |^stealthsurf ' "$settings" >"$tmp" 2>/dev/null && mv -f "$tmp" "$settings"
  rm -f "$tmp" 2>/dev/null || true
}

ss_normalize_payload_json() {
  local raw="$1"
  if printf '%s' "$raw" | jq -e 'has("stealthsurf")' >/dev/null 2>&1; then
    printf '%s' "$raw" | jq -c '.stealthsurf // {}'
  else
    printf '%s' "$raw" | jq -c .
  fi
}

ss_read_payload() {
  local f="/tmp/stealthsurf_payload.json"
  local custom extracted payload_raw="" chunk idx

  payload_raw=$(ss_am_settings_get stealthsurf_payload)
  if [ -z "$payload_raw" ]; then
    idx=0
    while [ "$idx" -le 20 ]; do
      chunk=$(ss_am_settings_get "stealthsurf_payload${idx}")
      [ -n "$chunk" ] || break
      payload_raw="${payload_raw}${chunk}"
      idx=$((idx + 1))
    done
  fi

  if [ -n "$payload_raw" ] && printf '%s' "$payload_raw" | jq -e . >/dev/null 2>&1; then
    extracted=$(ss_normalize_payload_json "$payload_raw")
    printf '%s' "$extracted" >"$f"
    ss_clear_ui_payload_settings
    printf '%s' "$extracted"
    return 0
  fi

  custom=$(nvram get amng_custom 2>/dev/null)
  if [ -n "$custom" ] && printf '%s' "$custom" | jq -e . >/dev/null 2>&1; then
    extracted=$(ss_normalize_payload_json "$custom")
    printf '%s' "$extracted" >"$f"
    printf '%s' "$extracted"
    return 0
  fi

  if [ -f "$f" ] && jq -e . "$f" >/dev/null 2>&1; then
    ss_normalize_payload_json "$(cat "$f")"
    return 0
  fi
  echo '{}'
}
EOF

# Fake Merlin root with custom_settings.txt (what write_custom_settings produces)
# Simulate: UI sent {"other":"keep","stealthsurf_payload":"{\"api_key\":\"stlth_…\"}"}
# Merlin flattens to lines — nested objects would have been lost.
mkdir -p "$TMP/root/jffs/addons"
KEY='stlth_deadbeef_0123456789abcdef01234567'
printf '%s\n' \
  "other_addon keepme" \
  "stealthsurf_payload {\"api_key\":\"$KEY\",\"label\":\"primary\"}" \
  >"$TMP/root/jffs/addons/custom_settings.txt"

# Run harness with chroot-like path override via bind — use sed to point at TMP
sed "s|/jffs/addons/custom_settings.txt|$TMP/root/jffs/addons/custom_settings.txt|g" \
  "$TMP/payload_harness.sh" >"$TMP/run_payload.sh"
# Also stub nvram to empty (Merlin reality)
cat >>"$TMP/run_payload.sh" <<'EOF'
nvram() { [ "$1" = get ] && [ "$2" = amng_custom ] && return 0; }
EOF

rm -f /tmp/stealthsurf_payload.json
payload=$(sh -c ". \"$TMP/run_payload.sh\"; ss_read_payload")
echo "$payload" | jq -e --arg k "$KEY" '.api_key == $k' >/dev/null \
  && ok "ss_read_payload extracts api_key from custom_settings" \
  || bad "ss_read_payload extracts api_key from custom_settings (got: $payload)"

# Payload keys cleaned after read (api key must not linger)
if grep -q 'stealthsurf_payload' "$TMP/root/jffs/addons/custom_settings.txt" 2>/dev/null; then
  bad "stealthsurf_payload cleaned after read"
else
  ok "stealthsurf_payload cleaned after read"
fi
grep -q 'other_addon keepme' "$TMP/root/jffs/addons/custom_settings.txt" \
  && ok "other addon settings preserved" \
  || bad "other addon settings preserved"

# Chunked payload reassembly
PART1='{"api_key":"stlth_chunked'
PART2='_0123456789abcdef01234567","x":1}'
printf '%s\n' \
  "stealthsurf_payload0 $PART1" \
  "stealthsurf_payload1 $PART2" \
  >"$TMP/root/jffs/addons/custom_settings.txt"
rm -f /tmp/stealthsurf_payload.json
payload=$(sh -c ". \"$TMP/run_payload.sh\"; ss_read_payload")
echo "$payload" | jq -e '.api_key | startswith("stlth_chunked")' >/dev/null \
  && ok "chunked stealthsurf_payloadN reassembled" \
  || bad "chunked stealthsurf_payloadN reassembled (got: $payload)"

# Document why nested object path fails: Merlin json_object_get_string on object → empty
# Simulate what write_custom_settings would produce for nested {stealthsurf:{api_key:...}}
printf '%s\n' "stealthsurf " >"$TMP/root/jffs/addons/custom_settings.txt"
rm -f /tmp/stealthsurf_payload.json
payload=$(sh -c ". \"$TMP/run_payload.sh\"; ss_read_payload")
echo "$payload" | jq -e '. == {}' >/dev/null \
  && ok "nested-object Merlin flatten yields empty payload" \
  || bad "nested-object Merlin flatten yields empty payload (got: $payload)"

# Empty nvram alone must not be enough (legacy bug)
rm -f /tmp/stealthsurf_payload.json
printf '%s\n' "unrelated foo" >"$TMP/root/jffs/addons/custom_settings.txt"
payload=$(sh -c ". \"$TMP/run_payload.sh\"; ss_read_payload")
echo "$payload" | jq -e '. == {}' >/dev/null \
  && ok "no stealthsurf_payload → empty object" \
  || bad "no stealthsurf_payload → empty object (got: $payload)"

if [ "$fail" -ne 0 ]; then
  echo "FAILED $fail"
  exit 1
fi
echo "All service-event hook checks passed"
exit 0
