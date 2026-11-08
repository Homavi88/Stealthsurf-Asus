#!/bin/sh
# Bypass / Redirect client policies by MAC

ss_policies_init() {
  ss_ensure_dirs
  [ -f "$SS_POLICIES_FILE" ] || echo '{"catchall":true,"rules":[]}' >"$SS_POLICIES_FILE"
}

# Build LAN device list from Merlin sources into one JSON array (no pipe/jq races).
ss_clientlist_json() {
  ss_ensure_dirs
  local raw leases neigh lines line name mac ip hostname state tmp
  tmp="$ADDON_TMP_DIR/clients_build.$$"
  : >"$tmp.raw"

  raw=$(nvram get custom_clientlist 2>/dev/null || true)
  if [ -n "$raw" ]; then
    printf '%s' "$raw" | tr '<' '\n' | while IFS= read -r line; do
      [ -z "$line" ] && continue
      name=$(printf '%s' "$line" | cut -d'>' -f1)
      mac=$(printf '%s' "$line" | cut -d'>' -f2 | tr 'a-z' 'A-Z')
      case "$mac" in
      *:*:*) printf 'C\t%s\t%s\t\n' "$mac" "$name" >>"$tmp.raw" ;;
      esac
    done
  fi

  leases="/var/lib/misc/dnsmasq.leases"
  [ -f "$leases" ] || leases="/tmp/var/lib/misc/dnsmasq.leases"
  if [ -f "$leases" ]; then
    while read -r _exp mac ip hostname _; do
      mac=$(printf '%s' "$mac" | tr 'a-z' 'A-Z')
      case "$mac" in
      *:*:*)
        [ "$hostname" = "*" ] && hostname=""
        printf 'D\t%s\t%s\t%s\n' "$mac" "${hostname:-}" "$ip" >>"$tmp.raw"
        ;;
      esac
    done <"$leases"
  fi

  if command -v ip >/dev/null 2>&1; then
    ip -4 neigh show 2>/dev/null | while read -r ip _dev _lladdr mac state rest; do
      case "$mac" in
      *:*:*)
        mac=$(printf '%s' "$mac" | tr 'a-z' 'A-Z')
        case "$state" in
        REACHABLE | STALE | DELAY | PROBE | PERMANENT | NOARP)
          printf 'A\t%s\t\t%s\n' "$mac" "$ip" >>"$tmp.raw"
          ;;
        esac
        ;;
      esac
    done
  elif [ -f /proc/net/arp ]; then
    # skip header
    tail -n +2 /proc/net/arp 2>/dev/null | while read -r ip _hw _flags mac _mask _dev; do
      mac=$(printf '%s' "$mac" | tr 'a-z' 'A-Z')
      case "$mac" in
      00:00:00:00:00:00 | *:*:*) ;;
      esac
      case "$mac" in
      00:00:00:00:00:00) continue ;;
      *:*:*) printf 'A\t%s\t\t%s\n' "$mac" "$ip" >>"$tmp.raw" ;;
      esac
    done
  fi

  # Merge in jq once (stable, no concurrent rewrite races)
  jq -Rn '
    reduce inputs as $line ({};
      ($line | split("\t")) as $p |
      if ($p|length) < 2 then . else
        ($p[1] | ascii_upcase) as $mac |
        ($p[0]) as $src |
        ($p[2] // "") as $name |
        ($p[3] // "") as $ip |
        .[$mac] = (
          (.[$mac] // {mac:$mac, name:"", ip:"", online:false, source:"unknown"})
          | .mac = $mac
          | (if ($name|length) > 0 then .name = $name else . end)
          | (if ($ip|length) > 0 then .ip = $ip else . end)
          | (if $src == "D" or $src == "A" then .online = true else . end)
          | (if $src == "C" then .source = "custom_clientlist"
             elif $src == "D" then .source = "dhcp"
             elif $src == "A" then .source = (if .source == "unknown" then "arp" else .source end)
             else . end)
        )
      end
    )
    | [.[]]
    | sort_by(.online|not, (.name // ""), (.ip // ""), .mac)
  ' "$tmp.raw" >"$tmp.json" 2>/dev/null || echo '[]' >"$tmp.json"

  # Always publish for WebUI soft-load
  cp -f "$tmp.json" "$SS_CACHE_CLIENTS" 2>/dev/null || true
  ln -sf "$SS_CACHE_CLIENTS" "$ADDON_WEB_DIR/clients.json" 2>/dev/null || true

  cat "$tmp.json"
  rm -f "$tmp.raw" "$tmp.json"
}

ss_clients_publish() {
  ss_clientlist_json >/dev/null
  ss_jq_file_or "$SS_CACHE_CLIENTS" '[]'
}

ss_policies_set() {
  local json="$1"
  ss_policies_init
  if ! printf '%s' "$json" | jq -e 'type == "object"' >/dev/null 2>&1; then
    ss_error "policies payload must be a JSON object"
    return 1
  fi
  ss_backup_auto "pre-policies" || true
  printf '%s' "$json" | jq '.' >"$SS_POLICIES_FILE"
  ss_log_policy_rules 2>/dev/null || true
  ss_log_devices_snapshot 2>/dev/null || true
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
