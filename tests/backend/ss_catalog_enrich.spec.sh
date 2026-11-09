#!/bin/sh
# Catalog enrichment: location titles + paid/cloud tag uniqueness
set -e
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat >"$TMP/locations.json" <<'EOF'
[
  { "id": 1, "code": "NL", "title": "Netherlands" },
  { "id": 2, "code": "DE", "title": "Germany" }
]
EOF

cat >"$TMP/configs.json" <<'EOF'
[
  { "id": 101, "protocol": "vless", "location_id": 1, "title": "NL VPN", "_ss_source": "config", "_ss_tag": "ss-101" },
  { "id": 55, "protocol": "vless", "location_id": 2, "title": "Paid DE", "_ss_source": "paid_option", "_ss_tag": "ss-po-55", "_ss_parent_id": 4 },
  { "id": 9, "protocol": "trojan", "location_id": 1, "title": "Cloud NL", "_ss_source": "cloud", "_ss_tag": "ss-cs-9", "_ss_parent_id": 3 }
]
EOF

jq --slurpfile loc "$TMP/locations.json" '
  ($loc[0] // []) as $L |
  map(
    . as $c |
    ($L | map(select((.id | tostring) == (($c.location_id // "") | tostring))) | first) as $hit |
    $c + { _ss_location_title: ($hit.title // $hit.code // null) }
  )
' "$TMP/configs.json" >"$TMP/enriched.json"

test "$(jq -r 'map(select(.id==101))[0]._ss_location_title' "$TMP/enriched.json")" = "Netherlands"
test "$(jq -r 'map(select(.id==55))[0]._ss_location_title' "$TMP/enriched.json")" = "Germany"
test "$(jq -r 'map(select(._ss_tag=="ss-po-55"))[0]._ss_source' "$TMP/enriched.json")" = "paid_option"
test "$(jq -r '[.[]._ss_tag] | unique | length' "$TMP/enriched.json")" = "3"

# Merge uniqueness by tag
jq -n --slurpfile a "$TMP/enriched.json" --slurpfile b "$TMP/enriched.json" '
  ($a[0] + $b[0]) | unique_by(._ss_tag) | length
' >"$TMP/merge_len.txt"
test "$(cat "$TMP/merge_len.txt")" = "3"

echo "ss_catalog_enrich.spec.sh OK"
