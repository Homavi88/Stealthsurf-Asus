#!/bin/sh
# Fingerprint + in-place refresh of imported StealthSurf outbounds (no route rewrite)
set -e
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat >"$TMP/xray.json" <<'EOF'
{
  "outbounds": [
    { "protocol": "freedom", "tag": "direct", "settings": {} },
    { "protocol": "vless", "tag": "ss-101", "_stealthsurf": true, "_ss_id": "101", "_ss_title": "NL", "settings": { "vnext": [{ "address": "old.example", "port": 443 }] } },
    { "protocol": "vless", "tag": "ss-202", "_stealthsurf": true, "_ss_id": "202", "_ss_title": "DE", "settings": { "vnext": [{ "address": "de.example", "port": 443 }] } }
  ],
  "routing": {
    "rules": [
      { "type": "field", "name": "stealthsurf-default", "outboundTag": "ss-101", "network": "tcp,udp", "enabled": true }
    ]
  }
}
EOF

cat >"$TMP/catalog.json" <<'EOF'
[
  { "id": 101, "protocol": "vless", "location_id": 1, "server_id": 10, "connection_url": "vless://a@new.example:443?type=tcp#NL", "xray_config": null, "awg_config": null, "title": "NL", "is_online": true },
  { "id": 202, "protocol": "vless", "location_id": 2, "server_id": 20, "connection_url": "vless://b@de.example:443?type=tcp#DE", "xray_config": null, "awg_config": null, "title": "DE", "is_online": false }
]
EOF

# Imported ids
ids=$(jq -r '
  [.outbounds[]?
    | select(._stealthsurf == true or ((.tag // "") | test("^ss-[0-9]+$")))
    | (._ss_id // (if ((.tag // "") | test("^ss-[0-9]+$")) then (.tag | sub("^ss-"; "")) else empty end))
    | select(. != null and . != "")
    | tostring
  ] | unique | .[]
' "$TMP/xray.json" | tr '\n' ' ')
test "$(printf '%s' "$ids" | awk '{$1=$1};1')" = "101 202"

fp1=$(jq -c --arg ids "101 202" '
  ($ids | split(" ") | map(select(length > 0))) as $want |
  [ .[]
    | select(. != null)
    | . as $c
    | select(($want | index(($c.id | tostring))) != null)
    | { id: ($c.id | tostring), protocol: $c.protocol, location_id: $c.location_id, server_id: $c.server_id,
        connection_url: $c.connection_url, xray_config: $c.xray_config, awg_config: $c.awg_config }
  ] | sort_by(.id)
' "$TMP/catalog.json" | md5sum | awk '{print $1}')

# Title-only change must keep the same connection fingerprint
jq 'map(if .id == 101 then .title = "NL renamed" else . end)' "$TMP/catalog.json" >"$TMP/catalog2.json"
fp2=$(jq -c --arg ids "101 202" '
  ($ids | split(" ") | map(select(length > 0))) as $want |
  [ .[]
    | select(. != null)
    | . as $c
    | select(($want | index(($c.id | tostring))) != null)
    | { id: ($c.id | tostring), protocol: $c.protocol, location_id: $c.location_id, server_id: $c.server_id,
        connection_url: $c.connection_url, xray_config: $c.xray_config, awg_config: $c.awg_config }
  ] | sort_by(.id)
' "$TMP/catalog2.json" | md5sum | awk '{print $1}')
test "$fp1" = "$fp2"

# URL change must change the fingerprint
jq 'map(if .id == 101 then .connection_url = "vless://a@changed.example:443?type=tcp#NL" else . end)' "$TMP/catalog.json" >"$TMP/catalog3.json"
fp3=$(jq -c --arg ids "101 202" '
  ($ids | split(" ") | map(select(length > 0))) as $want |
  [ .[]
    | select(. != null)
    | . as $c
    | select(($want | index(($c.id | tostring))) != null)
    | { id: ($c.id | tostring), protocol: $c.protocol, location_id: $c.location_id, server_id: $c.server_id,
        connection_url: $c.connection_url, xray_config: $c.xray_config, awg_config: $c.awg_config }
  ] | sort_by(.id)
' "$TMP/catalog3.json" | md5sum | awk '{print $1}')
test "$fp1" != "$fp3"

# In-place refresh keeps default route on ss-101
ob='{"protocol":"vless","tag":"ss-101","_stealthsurf":true,"_ss_id":"101","_ss_title":"NL","settings":{"vnext":[{"address":"changed.example","port":443}]}}'
jq --argjson ob "$ob" --arg tag "ss-101" '
  .outbounds = ((.outbounds // []) | map(if .tag == $tag then $ob else . end))
' "$TMP/xray.json" >"$TMP/refreshed.json"

test "$(jq -r '.routing.rules[] | select(.name=="stealthsurf-default") | .outboundTag' "$TMP/refreshed.json")" = "ss-101"
test "$(jq -r '.outbounds[] | select(.tag=="ss-101") | .settings.vnext[0].address' "$TMP/refreshed.json")" = "changed.example"
test "$(jq -r '.outbounds[] | select(.tag=="ss-202") | ._ss_title' "$TMP/refreshed.json")" = "DE"
test "$(jq -r '.outbounds | length' "$TMP/refreshed.json")" = "3"

echo "ss_catalog_sync.spec.sh OK"
