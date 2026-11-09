#!/bin/sh
# Smoke-test ensure_xray_scaffold jq transform (portable subset)
set -e
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat >"$TMP/empty.json" <<'EOF'
{"inbounds":[],"outbounds":[],"routing":{"rules":[]},"dns":{"servers":[]}}
EOF

jq '
  .log = (.log // {})
  | .log.loglevel = (.log.loglevel // "warning")
  | .inbounds = (.inbounds // [])
  | .outbounds = (.outbounds // [])
  | .routing = (.routing // {})
  | .routing.domainStrategy = (.routing.domainStrategy // "AsIs")
  | .routing.rules = (.routing.rules // [])
  | .dns = (.dns // {})
  | .dns.servers = (.dns.servers // ["localhost"])
  | if ([.inbounds[] | select(.tag == "all-in")] | length) > 0 then .
    else .inbounds += [{
      "protocol": "dokodemo-door",
      "listen": "127.0.0.1",
      "port": 5599,
      "tag": "all-in",
      "settings": { "address": "", "network": "tcp,udp", "followRedirect": true },
      "streamSettings": { "sockopt": { "tproxy": "tproxy" } },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
    }] end
  | if ([.outbounds[] | select(.tag == "direct" or .protocol == "freedom")] | length) > 0 then .
    else .outbounds = [{ "protocol": "freedom", "tag": "direct", "settings": {} }] + .outbounds end
  | if ([.outbounds[] | select(.tag == "block" or .protocol == "blackhole")] | length) > 0 then .
    else .outbounds += [{ "protocol": "blackhole", "tag": "block", "settings": {} }] end
' "$TMP/empty.json" >"$TMP/out.json"

test "$(jq -r '.inbounds[0].tag' "$TMP/out.json")" = "all-in"
test "$(jq -r '.outbounds[0].tag' "$TMP/out.json")" = "direct"
test "$(jq -r '.outbounds[1].tag' "$TMP/out.json")" = "block"

# Import-style: keep direct first, append proxy, set stealthsurf-default rule
ob='{"protocol":"vless","tag":"ss-101","settings":{}}'
jq --argjson ob "$ob" --arg tag "ss-101" '
  .outbounds = ((.outbounds // []) | map(select(.tag != $tag)))
  | .outbounds = (
      ([.outbounds[] | select(.protocol == "freedom" or .tag == "direct")])
      + [$ob]
      + ([.outbounds[] | select(.protocol != "freedom" and .tag != "direct")])
    )
  | .routing //= {}
  | .routing.rules //= []
  | .routing.rules = (
      (.routing.rules | map(select(.name != "stealthsurf-default" and .outboundTag != $tag)))
      + [{
          "type": "field",
          "name": "stealthsurf-default",
          "outboundTag": $tag,
          "network": "tcp,udp",
          "enabled": true
        }]
    )
' "$TMP/out.json" >"$TMP/imp.json"

test "$(jq -r '.outbounds[0].tag' "$TMP/imp.json")" = "direct"
test "$(jq -r '.outbounds[1].tag' "$TMP/imp.json")" = "ss-101"
test "$(jq -r '.routing.rules[-1].name' "$TMP/imp.json")" = "stealthsurf-default"
test "$(jq -r '.routing.rules[-1].outboundTag' "$TMP/imp.json")" = "ss-101"

echo "scaffold.spec.sh OK"
