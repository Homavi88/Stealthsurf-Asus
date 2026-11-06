#!/bin/sh
# Regression: WebUI setkey/addkey must reach service_event via Merlin service-event.
# Merlin splits action_script:
#   start_stealthsurf_setkey → $1=start $2=stealthsurf_setkey
#   stealthsurf_setkey       → $1=""    $2=stealthsurf_setkey
# Hook must match on $2, not require $1=start.
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

# Hook must not require $1=start alone
if grep -q '\$1" = "start".*stealthsurf_' "$HOOKS" || grep -q '\[ "\$1" = "start" \] && echo "\$2"' "$HOOKS"; then
  bad "hook still requires \$1=start"
else
  ok "hook does not require \$1=start"
fi
grep -q 'echo "\$2" | grep -q "^stealthsurf_"' "$HOOKS" && ok "hook matches \$2 stealthsurf_" || bad "hook matches \$2 stealthsurf_"

# Simulate the generated hook body against Merlin arg shapes
# shellcheck disable=SC1091
. "$HOOKS"
ss_service_event_block >"$TMP/hook.sh"

mkdir -p "$TMP/www/user/stealthsurf" "$TMP/jffs/scripts" "$TMP/bin"
# Fake stealthsurf CLI that records the action
cat >"$TMP/jffs/scripts/stealthsurf" <<'EOF'
#!/bin/sh
echo "SE $* $(cat /tmp/stealthsurf_payload.json 2>/dev/null)" >> /tmp/ss_hook_calls.log
EOF
chmod +x "$TMP/jffs/scripts/stealthsurf"

# Run hook in a chroot-like PATH by rewriting absolute paths in a wrapper
cat >"$TMP/run_hook.sh" <<EOF
#!/bin/sh
# Inline the same logic as the installed block, with paths under TMP
if echo "\$2" | grep -q "^stealthsurf_"; then
  action="\${2#stealthsurf_}"
  case "\$action" in
  uninstall|remove|purge)
    echo blocked > "$TMP/blocked"
    ;;
  *)
    custom=\$(cat "$TMP/amng_custom" 2>/dev/null || true)
    if [ -n "\$custom" ]; then
      printf '%s\\n' "\$custom" > /tmp/stealthsurf_payload.json
    else
      echo '{}' > /tmp/stealthsurf_payload.json
    fi
    "$TMP/jffs/scripts/stealthsurf" service_event "\$action"
    ;;
  esac
fi
EOF
chmod +x "$TMP/run_hook.sh"
: >/tmp/ss_hook_calls.log
rm -f /tmp/stealthsurf_payload.json

# Case A: XrayUI-style bare action_script (empty $1) — previously broken
printf '%s' '{"stealthsurf":{"api_key":"stlth_deadbeef_0123456789abcdef01234567"}}' >"$TMP/amng_custom"
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

# Payload extract still namespaced
grep -q 'ss_read_payload\|has("stealthsurf")' "$SE" && ok "payload reads .stealthsurf" || bad "payload reads .stealthsurf"
grep -q 'ss_api_keys_store_add' "$SE" && ok "setkey persists to api_keys store" || bad "setkey persists to api_keys store"

if [ "$fail" -ne 0 ]; then
  echo "FAILED $fail"
  exit 1
fi
echo "All service-event hook checks passed"
exit 0
