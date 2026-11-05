#!/bin/sh
# Multi-outbound catalog + domain→ss-<id> routing generator

ss_outbound_tag() {
  printf 'ss-%s' "$1"
}

ss_load_outbounds_meta() {
  ss_ensure_dirs
  if [ ! -f "$SS_OUTBOUNDS_FILE" ]; then
    echo '{"enabled":[],"default":""}' >"$SS_OUTBOUNDS_FILE"
  fi
}

ss_set_enabled_outbounds() {
  # ss_set_enabled_outbounds <json array of ids> [default tag or id]
  local enabled_json="$1"
  local default="$2"
  ss_load_outbounds_meta
  jq -nc --argjson enabled "$enabled_json" --arg default "${default:-}" '
    {
      enabled: ($enabled | map(tonumber? // .)),
      default: (if $default == "" then (if ($enabled|length)>0 then ("ss-" + ($enabled[0]|tostring)) else "direct" end) else $default end)
    }' >"$SS_OUTBOUNDS_FILE"
  SS_ENABLED_OUTBOUNDS=$(jq -r '.enabled | map(tostring) | join(" ")' "$SS_OUTBOUNDS_FILE")
  SS_DEFAULT_OUTBOUND=$(jq -r '.default' "$SS_OUTBOUNDS_FILE")
  ss_save_conf
}

ss_enable_outbound() {
  local id="$1"
  ss_load_outbounds_meta
  jq --argjson id "$id" '
    .enabled = ((.enabled // []) + [$id] | unique) |
    if (.default // "") == "" then .default = ("ss-" + ($id|tostring)) else . end
  ' "$SS_OUTBOUNDS_FILE" >"$SS_OUTBOUNDS_FILE.tmp" && mv "$SS_OUTBOUNDS_FILE.tmp" "$SS_OUTBOUNDS_FILE"
  SS_ENABLED_OUTBOUNDS=$(jq -r '.enabled | map(tostring) | join(" ")' "$SS_OUTBOUNDS_FILE")
  SS_DEFAULT_OUTBOUND=$(jq -r '.default' "$SS_OUTBOUNDS_FILE")
  ss_save_conf
}

ss_disable_outbound() {
  local id="$1"
  ss_load_outbounds_meta
  jq --argjson id "$id" '
    .enabled = ((.enabled // []) | map(select(. != $id))) |
    if (.default == ("ss-" + ($id|tostring))) then
      .default = (if (.enabled|length)>0 then ("ss-" + (.enabled[0]|tostring)) else "direct" end)
    else . end
  ' "$SS_OUTBOUNDS_FILE" >"$SS_OUTBOUNDS_FILE.tmp" && mv "$SS_OUTBOUNDS_FILE.tmp" "$SS_OUTBOUNDS_FILE"
  SS_ENABLED_OUTBOUNDS=$(jq -r '.enabled | map(tostring) | join(" ")' "$SS_OUTBOUNDS_FILE")
  SS_DEFAULT_OUTBOUND=$(jq -r '.default' "$SS_OUTBOUNDS_FILE")
  ss_save_conf
}

ss_set_default_outbound() {
  local tag="$1"
  ss_load_outbounds_meta
  case "$tag" in
  direct | block | ss-*) ;;
  *)
    # numeric id
    tag=$(ss_outbound_tag "$tag")
    ;;
  esac
  # Validate reference to enabled outbound
  case "$tag" in
  ss-*)
    local id="${tag#ss-}"
    if ! jq -e --argjson id "$id" '(.enabled // []) | index($id) != null' "$SS_OUTBOUNDS_FILE" >/dev/null 2>&1; then
      ss_error "Cannot set default to disabled/missing outbound $tag"
      return 1
    fi
    ;;
  esac
  jq --arg tag "$tag" '.default = $tag' "$SS_OUTBOUNDS_FILE" >"$SS_OUTBOUNDS_FILE.tmp" && mv "$SS_OUTBOUNDS_FILE.tmp" "$SS_OUTBOUNDS_FILE"
  SS_DEFAULT_OUTBOUND="$tag"
  ss_save_conf
}

ss_routing_validate() {
  # Ensure every rule outbound references enabled ss-<id>, direct, or block
  local bad
  bad=$(jq -r --slurpfile ob "$SS_OUTBOUNDS_FILE" '
    ($ob[0].enabled // []) as $en |
    (.rules // [])[] |
    .outbound as $o |
    select(
      ($o != "direct") and ($o != "block") and
      (($o | startswith("ss-") | not) or ((($o | ltrimstr("ss-") | tonumber?) as $id | ($en | index($id)) == null)))
    ) |
    "\(.name // .matcher // "?") -> \($o)"
  ' "$SS_ROUTING_FILE" 2>/dev/null)
  if [ -n "$bad" ]; then
    ss_error "Routing rules reference disabled/unknown outbounds:"
    printf '%s\n' "$bad" | while read -r line; do ss_error "  $line"; done
    return 1
  fi
  return 0
}

ss_routing_add_rule() {
  # payload JSON: {matcher, type, outbound, priority?, name?}
  local rule_json="$1"
  ss_ensure_dirs
  jq --argjson rule "$rule_json" '
    .rules = ((.rules // []) + [$rule + {priority: ($rule.priority // ((.rules|length)+1))}]) |
    .rules |= sort_by(.priority // 9999)
  ' "$SS_ROUTING_FILE" >"$SS_ROUTING_FILE.tmp" && mv "$SS_ROUTING_FILE.tmp" "$SS_ROUTING_FILE"
  ss_routing_validate
}

ss_routing_set_rules() {
  local rules_json="$1"
  local default="$2"
  local preset="$3"
  ss_ensure_dirs
  jq -nc --argjson rules "$rules_json" --arg default "${default:-}" --arg preset "${preset:-}" '
    {
      domainStrategy: "AsIs",
      default_outbound: $default,
      preset: $preset,
      rules: ($rules | sort_by(.priority // 9999))
    }' >"$SS_ROUTING_FILE"
  [ -n "$default" ] && ss_set_default_outbound "$default" || true
  ss_routing_validate
}

ss_routing_apply_preset() {
  local preset="$1"
  local default_id="$2"
  local alt_id="$3"
  local default_tag alt_tag rules
  default_tag=$(ss_outbound_tag "${default_id:-0}")
  alt_tag=$(ss_outbound_tag "${alt_id:-0}")

  case "$preset" in
  all-vpn)
    rules='[]'
    default_tag="$default_tag"
    ;;
  ru-direct)
    rules=$(jq -nc --arg def "$default_tag" '[
      {"name":"private","type":"geoip","matcher":"private","outbound":"direct","priority":10},
      {"name":"ru-ip","type":"geoip","matcher":"ru","outbound":"direct","priority":20},
      {"name":"ru-domain","type":"geosite","matcher":"category-ru","outbound":"direct","priority":30}
    ]')
    ;;
  streaming-split)
    rules=$(jq -nc --arg a "$alt_tag" '[
      {"name":"netflix","type":"geosite","matcher":"netflix","outbound":$a,"priority":10},
      {"name":"youtube","type":"geosite","matcher":"youtube","outbound":$a,"priority":20},
      {"name":"disney","type":"geosite","matcher":"disney","outbound":$a,"priority":30},
      {"name":"private","type":"geoip","matcher":"private","outbound":"direct","priority":5}
    ]')
    ;;
  block-ads)
    rules=$(jq -nc --arg def "$default_tag" '[
      {"name":"ads","type":"geosite","matcher":"category-ads-all","outbound":"block","priority":5},
      {"name":"malware","type":"geosite","matcher":"category-malware","outbound":"block","priority":6},
      {"name":"private","type":"geoip","matcher":"private","outbound":"direct","priority":10}
    ]')
    ;;
  *)
    ss_error "Unknown preset: $preset (all-vpn|ru-direct|streaming-split|block-ads)"
    return 1
    ;;
  esac

  ss_routing_set_rules "$rules" "$default_tag" "$preset"
  ss_ok "Applied routing preset $preset (default=$default_tag)"
}

ss_collect_endpoints() {
  # Write endpoint IPs/hosts of enabled outbounds for anti-loop
  local id entry link host
  local tmp="$ADDON_TMP_DIR/endpoints.$$"
  echo '[]' >"$tmp"
  for id in $SS_ENABLED_OUTBOUNDS; do
    [ -n "$id" ] || continue
    entry=$(ss_cache_get_config "$id" 2>/dev/null) || continue
    [ -n "$entry" ] && [ "$entry" != "null" ] || continue
    link=$(printf '%s' "$entry" | jq -r '.connection_url // empty')
    [ -n "$link" ] || continue
    host=$(ss_extract_host_from_link "$link")
    [ -n "$host" ] || continue
    jq --arg addr "$host" --argjson id "$id" \
      '. + [{config_id:$id, address:$addr}]' "$tmp" >"$tmp.n" && mv "$tmp.n" "$tmp"
  done
  # Also active single config
  if [ -n "$SS_ACTIVE_CONFIG_ID" ]; then
    entry=$(ss_cache_get_config "$SS_ACTIVE_CONFIG_ID" 2>/dev/null) || true
    if [ -n "$entry" ] && [ "$entry" != "null" ]; then
      link=$(printf '%s' "$entry" | jq -r '.connection_url // empty')
      host=$(ss_extract_host_from_link "$link")
      [ -n "$host" ] && jq --arg addr "$host" --argjson id "$SS_ACTIVE_CONFIG_ID" \
        '. + [{config_id:$id, address:$addr}] | unique_by(.address)' "$tmp" >"$tmp.n" && mv "$tmp.n" "$tmp"
    fi
  fi
  mv "$tmp" "$SS_ENDPOINTS_FILE"
}

ss_extract_host_from_link() {
  local link="$1"
  local rest hostport
  case "$link" in
  vless://* | trojan://*)
    rest="${link#*://}"
    rest="${rest#*@}"
    rest="${rest%%\?*}"
    rest="${rest%%#*}"
    hostport="$rest"
    ;;
  ss://*)
    rest="${link#ss://}"
    rest="${rest%%\?*}"
    rest="${rest%%#*}"
    case "$rest" in
    *@*) hostport="${rest#*@}" ;;
    *)
      # base64 form — best effort
      hostport=""
      ;;
    esac
    ;;
  hy2://* | hysteria2://*)
    rest="${link#*://}"
    rest="${rest#*@}"
    rest="${rest%%\?*}"
    rest="${rest%%#*}"
    hostport="$rest"
    ;;
  *)
    hostport=""
    ;;
  esac
  case "$hostport" in
  \[*\])
    # [2001:db8::1]:443 or [2001:db8::1]
    hostport="${hostport#\[}"
    printf '%s' "${hostport%%]*}"
    ;;
  *:*)
    # hostname:port — take left of last colon only for IPv4/host
    case "$hostport" in
    *:*.*) printf '%s' "$hostport" ;; # unlikely
    *) printf '%s' "${hostport%:*}" ;;
    esac
    ;;
  *)
    printf '%s' "$hostport"
    ;;
  esac
}

ss_build_routing_rules_json() {
  # Emit Xray routing.rules array from SS_ROUTING_FILE + private + endpoints
  local default_tag
  default_tag="${SS_DEFAULT_OUTBOUND:-direct}"
  [ -n "$default_tag" ] || default_tag="direct"
  if [ -f "$SS_OUTBOUNDS_FILE" ]; then
    default_tag=$(jq -r '.default // "direct"' "$SS_OUTBOUNDS_FILE")
  fi

  jq -nc --slurpfile rt "$SS_ROUTING_FILE" --slurpfile ep "$SS_ENDPOINTS_FILE" --arg def "$default_tag" '
    def rule_from(r):
      (r.type // "domain") as $t |
      (r.matcher // r.value // "") as $m |
      (r.outbound // $def) as $o |
      if $t == "geoip" or $t == "ip" or $t == "cidr" then
        {type:"field", outboundTag:$o, ip: (if $t=="geoip" then ["geoip:"+$m] else [$m] end)}
      elif $t == "geosite" then
        {type:"field", outboundTag:$o, domain: ["geosite:"+$m]}
      elif $t == "full" then
        {type:"field", outboundTag:$o, domain: ["full:"+$m]}
      elif $t == "keyword" then
        {type:"field", outboundTag:$o, domain: ["keyword:"+$m]}
      elif $t == "regexp" then
        {type:"field", outboundTag:$o, domain: ["regexp:"+$m]}
      else
        {type:"field", outboundTag:$o, domain: ["domain:"+$m]}
      end;

    [
      {type:"field", outboundTag:"direct", ip:["geoip:private"]},
      (($ep[0] // []) | map(select(.address != null and .address != "")) | unique_by(.address) |
        if length > 0 then {type:"field", outboundTag:"direct", domain: (map(.address) | map("full:"+.)), ip: map(.address)} else empty end),
      ((($rt[0].rules // []) | sort_by(.priority // 9999))[] | rule_from(.))
    ]
  '
}

ss_build_multi_outbounds() {
  # Build JSON array of outbound objects for all enabled configs
  local id entry link outbound tag proto runtime
  local list="[]"
  local tmp="$ADDON_TMP_DIR/outbounds.$$"
  echo '[]' >"$tmp"

  # Ensure we have something to enable
  if [ -z "$SS_ENABLED_OUTBOUNDS" ] && [ -n "$SS_ACTIVE_CONFIG_ID" ]; then
    SS_ENABLED_OUTBOUNDS="$SS_ACTIVE_CONFIG_ID"
  fi

  for id in $SS_ENABLED_OUTBOUNDS; do
    [ -n "$id" ] || continue
    entry=$(ss_cache_get_config "$id") || continue
    [ -n "$entry" ] && [ "$entry" != "null" ] || {
      ss_warn "Config $id not in cache"
      continue
    }
    proto=$(printf '%s' "$entry" | jq -r '.protocol // "vless"')
    runtime=$(ss_protocol_runtime "$proto")
    if [ "$runtime" != "xray" ] && [ "$runtime" != "unsupported" ]; then
      # Non-xray runtimes are started separately; still add a freedom dialer via socks if local bridge exists
      ss_info "Config $id uses runtime $runtime — outbound bridge tag ss-$id (see protocols)"
    fi
    link=$(printf '%s' "$entry" | jq -r '.connection_url // empty')
    if [ -z "$link" ]; then
      ss_warn "Config $id has empty connection_url"
      continue
    fi
    if [ "$runtime" = "xray" ] || [ "$runtime" = "unsupported" ]; then
      if [ "$runtime" = "unsupported" ]; then
        ss_warn "Protocol $proto for config $id is unsupported — skipping outbound"
        continue
      fi
      outbound=$(ss_parse_link_to_outbound "$link") || {
        ss_warn "Failed to parse link for config $id"
        continue
      }
      tag=$(ss_outbound_tag "$id")
      outbound=$(printf '%s' "$outbound" | jq --arg tag "$tag" '.tag = $tag')
      jq --argjson ob "$outbound" '. + [$ob]' "$tmp" >"$tmp.n" && mv "$tmp.n" "$tmp"
    fi
  done

  # Always include direct + block
  jq '. + [
    {tag:"direct", protocol:"freedom"},
    {tag:"block", protocol:"blackhole"}
  ]' "$tmp"
  rm -f "$tmp" "$tmp.n"
}
