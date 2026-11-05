#!/bin/sh
# Bypass / Redirect client policies by MAC

ss_policies_init() {
  ss_ensure_dirs
  [ -f "$SS_POLICIES_FILE" ] || echo '{"catchall":true,"rules":[]}' >"$SS_POLICIES_FILE"
}

ss_clientlist_json() {
  # Merlin clientlist from custom_clientlist / dhcp / arp
  local tmp="$ADDON_TMP_DIR/clients.$$"
  echo '[]' >"$tmp"

  # Prefer nvram custom_clientlist (name>mac>...)
  local raw
  raw=$(nvram get custom_clientlist 2>/dev/null || true)
  if [ -n "$raw" ]; then
    printf '%s' "$raw" | tr '<' '\n' | while IFS= read -r line; do
      [ -z "$line" ] && continue
      name=$(printf '%s' "$line" | cut -d'>' -f1)
      mac=$(printf '%s' "$line" | cut -d'>' -f2 | tr 'a-z' 'A-Z')
      [ -n "$mac" ] || continue
      jq --arg name "$name" --arg mac "$mac" --arg src "custom_clientlist" \
        '. + [{name:$name, mac:$mac, source:$src, online:false}]' "$tmp" >"$tmp.n" && mv "$tmp.n" "$tmp"
    done
  fi

  # Merge DHCP leases
  if [ -f /var/lib/misc/dnsmasq.leases ]; then
    while read -r _exp mac ip hostname _; do
      mac=$(printf '%s' "$mac" | tr 'a-z' 'A-Z')
      [ -n "$mac" ] || continue
      jq --arg name "${hostname:-}" --arg mac "$mac" --arg ip "$ip" --arg src "dhcp" \
        '
        ($mac) as $m |
        if any(.[]; .mac == $m) then
          map(if .mac == $m then .ip = $ip | .online = true | (if (.name|length)==0 and ($name|length)>0 then .name = $name else . end) else . end)
        else
          . + [{name:$name, mac:$mac, ip:$ip, source:$src, online:true}]
        end
        ' "$tmp" >"$tmp.n" && mv "$tmp.n" "$tmp"
    done </var/lib/misc/dnsmasq.leases
  fi

  # ARP online flag
  if command -v ip >/dev/null 2>&1; then
    ip -4 neigh show 2>/dev/null | while read -r ip _dev _lladdr mac state; do
      case "$mac" in
      *:*:*)
        mac=$(printf '%s' "$mac" | tr 'a-z' 'A-Z')
        jq --arg mac "$mac" --arg ip "$ip" '
          map(if .mac == $mac then .online = true | .ip = $ip else . end)
        ' "$tmp" >"$tmp.n" && mv "$tmp.n" "$tmp"
        ;;
      esac
    done
  fi

  cat "$tmp"
  rm -f "$tmp" "$tmp.n"
}

ss_policies_set() {
  local json="$1"
  ss_policies_init
  if ! printf '%s' "$json" | jq -e 'type == "object"' >/dev/null 2>&1; then
    ss_error "policies payload must be a JSON object"
    return 1
  fi
  printf '%s' "$json" | jq '.' >"$SS_POLICIES_FILE"
  ss_ok "Policies saved ($(jq '.rules|length' "$SS_POLICIES_FILE") rules)"
}

ss_policies_add() {
  local rule_json="$1"
  ss_policies_init
  jq --argjson rule "$rule_json" '.rules = ((.rules // []) + [$rule])' \
    "$SS_POLICIES_FILE" >"$SS_POLICIES_FILE.tmp" && mv "$SS_POLICIES_FILE.tmp" "$SS_POLICIES_FILE"
}

ss_policies_delete() {
  local mac="$1"
  local idx="$2"
  ss_policies_init
  mac=$(printf '%s' "$mac" | tr 'a-z' 'A-Z')
  if [ -n "$idx" ]; then
    jq --argjson idx "$idx" 'del(.rules[$idx])' "$SS_POLICIES_FILE" >"$SS_POLICIES_FILE.tmp" && mv "$SS_POLICIES_FILE.tmp" "$SS_POLICIES_FILE"
  else
    jq --arg mac "$mac" '.rules = ((.rules // []) | map(select((.mac|ascii_upcase) != $mac)))' \
      "$SS_POLICIES_FILE" >"$SS_POLICIES_FILE.tmp" && mv "$SS_POLICIES_FILE.tmp" "$SS_POLICIES_FILE"
  fi
}

ss_policies_get() {
  ss_policies_init
  cat "$SS_POLICIES_FILE"
}
