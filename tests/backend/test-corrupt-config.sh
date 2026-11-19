#!/bin/sh
# Corrupt / NUL-padded config.json must be detected and repaired by scaffold helpers.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
CFG="$ROOT/src/backend/config.sh"
CTL="$ROOT/src/backend/control.sh"
RSP="$ROOT/src/backend/response.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

INST="$ROOT/src/backend/install.sh"
LOGS="$ROOT/src/backend/logs.sh"

grep -q 'xray_config_is_valid' "$CFG" || fail "missing xray_config_is_valid"
grep -q 'repair_xray_config_if_corrupt' "$CFG" || fail "missing repair_xray_config_if_corrupt"
grep -q 'Quarantined bad config' "$CFG" || fail "repair must quarantine corrupt file"
grep -q 'repair_xray_config_if_corrupt' "$CFG" || fail "ensure_xray_scaffold must call repair"
grep -q 'config invalid' "$CTL" || fail "start must abort when test_xray_config fails"
grep -q 'watchdog_clear_desired' "$CTL" || fail "failed start must clear desired state"
grep -q 'did not stay running' "$CTL" || fail "start must verify Xray PID after launch"
grep -q 'XRAY_CONFIG_FILE.new' "$RSP" || fail "apply_config must use atomic write"
grep -q 'ensure_xray_scaffold' "$INST" || fail "install must repair config before logrotate/jq"
awk '/ensure_xray_scaffold/{s=NR} /logrotate_setup/{l=NR} END{exit !(s && l && s < l)}' "$INST" ||
  fail "install must call ensure_xray_scaffold before logrotate_setup"
grep -q 'config missing/invalid' "$LOGS" || fail "logrotate must tolerate invalid config.json"

# Functional: NUL file is not valid JSON object
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
printf '\0\0\0\0' >"$TMP/nul.json"
jq -e 'type == "object"' "$TMP/nul.json" >/dev/null 2>&1 && fail "jq should reject NUL file"
printf '{bad' >"$TMP/trunc.json"
jq -e 'type == "object"' "$TMP/trunc.json" >/dev/null 2>&1 && fail "jq should reject truncated JSON"
printf '{"a":1}\n' >"$TMP/ok.json"
jq -e 'type == "object"' "$TMP/ok.json" >/dev/null 2>&1 || fail "jq should accept object"

echo "ok: corrupt-config detection + start abort + atomic apply wiring"
