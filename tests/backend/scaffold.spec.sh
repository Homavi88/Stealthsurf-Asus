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

# DNS leak wiring: upstream through the imported proxy, hijack tproxy port 53
jq --arg tag "ss-101" '
  .dns //= {}
  | .dns.tag = (.dns.tag // "dnsQuery")
  | .dns.servers = (
      (.dns.servers // []) as $s
      | if ($s | length) == 0 then ["1.1.1.1", "localhost"]
        elif (($s | map(if type == "string" then . else (.address // "") end) | unique) == ["localhost"]) then ["1.1.1.1"] + $s
        else $s end
    )
  | if ([.inbounds[]? | select(.tag == "sys:dns-in")] | length) > 0 then .
    else .inbounds += [{
      "protocol": "dokodemo-door",
      "listen": "127.0.0.1",
      "port": 53000,
      "tag": "sys:dns-in",
      "settings": { "address": "1.1.1.1", "port": 53, "network": "tcp,udp", "followRedirect": false }
    }] end
  | if ([.outbounds[]? | select(.tag == "sys:dns-out")] | length) > 0 then .
    else .outbounds += [{ "protocol": "dns", "tag": "sys:dns-out", "settings": {} }] end
  | .routing //= {}
  | .routing.rules //= []
  | .routing.rules = (.routing.rules | map(select(.name != "sys:dns.intercept" and .name != "sys:dns.upstream" and .name != "sys:dns.hijack")))
  | ([.inbounds[]? | select(.tag != "sys:dns-in" and ((.streamSettings.sockopt.tproxy // "") == "tproxy") and ((.tag // "") != ""))] | map(.tag)) as $tp
  | .routing.rules = (
      [
        { "type": "field", "name": "sys:dns.intercept", "idx": -3, "inboundTag": ["sys:dns-in"], "outboundTag": "sys:dns-out", "enabled": true },
        { "type": "field", "name": "sys:dns.upstream", "idx": -2, "inboundTag": [(.dns.tag // "dnsQuery")], "outboundTag": $tag, "enabled": true }
      ]
      + (if ($tp | length) > 0 then
          [{ "type": "field", "name": "sys:dns.hijack", "idx": -1, "inboundTag": $tp, "port": "53", "network": "tcp,udp", "outboundTag": "sys:dns-out", "enabled": true }]
        else [] end)
      + .routing.rules
    )
' "$TMP/imp.json" >"$TMP/dns.json"

test "$(jq -r '.dns.tag' "$TMP/dns.json")" = "dnsQuery"
test "$(jq -r '.dns.servers[0]' "$TMP/dns.json")" = "1.1.1.1"
test "$(jq -r '.inbounds[] | select(.tag=="sys:dns-in") | .port' "$TMP/dns.json")" = "53000"
test "$(jq -r '.outbounds[] | select(.tag=="sys:dns-out") | .protocol' "$TMP/dns.json")" = "dns"
test "$(jq -r '.routing.rules[] | select(.name=="sys:dns.upstream") | .outboundTag' "$TMP/dns.json")" = "ss-101"
test "$(jq -r '.routing.rules[] | select(.name=="sys:dns.hijack") | .inboundTag[0]' "$TMP/dns.json")" = "all-in"
test "$(jq -r '.routing.rules[] | select(.name=="sys:dns.hijack") | .port' "$TMP/dns.json")" = "53"

# Catalog stamp of API titles onto ss-<id>
echo '[{"id":101,"title":"Netherlands VLESS XHTTP","is_online":true}]' >"$TMP/cat.json"
jq --slurpfile cat "$TMP/cat.json" '
  ($cat[0] // []) as $c |
  .outbounds = ((.outbounds // []) | map(
    if ((.tag // "") | test("^ss-[0-9]+$")) then
      ((.tag | sub("^ss-"; "")) as $id |
      ($c | map(select((.id | tostring) == $id)) | first) as $m |
      if $m != null then
        . + { _stealthsurf: true, _ss_id: $m.id, _ss_title: ($m.title // $m.name // .tag), _ss_online: ($m.is_online // false) }
      else . end)
    else . end
  ))
' "$TMP/dns.json" >"$TMP/stamp.json"
test "$(jq -r '.outbounds[] | select(.tag=="ss-101") | ._ss_title' "$TMP/stamp.json")" = "Netherlands VLESS XHTTP"
test "$(jq -r '.outbounds[] | select(.tag=="ss-101") | ._ss_online' "$TMP/stamp.json")" = "true"

echo "scaffold.spec.sh OK"
