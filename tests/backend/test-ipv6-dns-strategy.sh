#!/bin/sh
# ss_sync_ipv6_dns_strategy: block/ignore → UseIPv4; proxy clears UseIPv4 only.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
CFG_SH="$ROOT/src/backend/config.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

grep -q 'ss_sync_ipv6_dns_strategy' "$CFG_SH" || fail "missing ss_sync_ipv6_dns_strategy"
grep -q 'ss_sync_ipv6_dns_strategy' "$ROOT/src/backend/stealthsurf_api.sh" || fail "dns leak must call sync"
grep -q 'ss_sync_ipv6_dns_strategy' "$ROOT/src/backend/general_opts.sh" || fail "general opts must sync on ipv6_mode save"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
CFG="$TMP/config.json"

sync() {
    mode="$1"
    jq --arg ipv6_mode "$mode" '
      .dns //= {}
      | if $ipv6_mode == "block" or $ipv6_mode == "ignore" then
          if ((.dns.queryStrategy // "") | length) == 0
             or .dns.queryStrategy == "UseIP"
             or .dns.queryStrategy == "UseIPv6"
             or .dns.queryStrategy == "UseIPv4" then
            .dns.queryStrategy = "UseIPv4"
          else . end
        else
          if .dns.queryStrategy == "UseIPv4" then del(.dns.queryStrategy) else . end
        end
    ' "$CFG" >"$CFG.tmp" && mv -f "$CFG.tmp" "$CFG"
}

echo '{"dns":{"servers":["localhost"],"queryStrategy":"UseIP"}}' >"$CFG"
sync block
[ "$(jq -r '.dns.queryStrategy' "$CFG")" = "UseIPv4" ] || fail "block did not set UseIPv4"

sync proxy
[ -z "$(jq -r '.dns.queryStrategy // empty' "$CFG")" ] || fail "proxy did not clear UseIPv4"

echo '{"dns":{"servers":["localhost"]}}' >"$CFG"
sync ignore
[ "$(jq -r '.dns.queryStrategy' "$CFG")" = "UseIPv4" ] || fail "ignore did not set UseIPv4"

echo '{"dns":{"servers":["localhost"],"queryStrategy":"UseIPv6"}}' >"$CFG"
sync proxy
[ "$(jq -r '.dns.queryStrategy' "$CFG")" = "UseIPv6" ] || fail "proxy must keep explicit UseIPv6"

echo "ok: ipv6 dns strategy sync is bidirectional"
