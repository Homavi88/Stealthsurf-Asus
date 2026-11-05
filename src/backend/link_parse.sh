#!/bin/sh

# Convert StealthSurf connection_url (share link) into an Xray outbound object (JSON).

ss_parse_vless() {
  local link="$1"
  local rest uuid hostport host port qs name
  local encryption security type flow sni fp pbk sid spx path host_header
  local mode service_name alpn

  rest="${link#vless://}"
  name=""
  case "$rest" in
  *#*)
    name=$(ss_urldecode "${rest#*#}")
    rest="${rest%%#*}"
    ;;
  esac
  uuid="${rest%%@*}"
  rest="${rest#*@}"
  qs=""
  case "$rest" in
  *\?*)
    qs="${rest#*\?}"
    hostport="${rest%%\?*}"
    ;;
  *) hostport="$rest" ;;
  esac

  case "$hostport" in
  \[*\])
    host="${hostport%]*}"
    host="${host#\[}"
    port="443"
    ;;
  *:*)
    host="${hostport%:*}"
    port="${hostport##*:}"
    ;;
  *)
    host="$hostport"
    port="443"
    ;;
  esac

  encryption=$(ss_get_query_param "$qs" encryption 2>/dev/null || echo none)
  security=$(ss_get_query_param "$qs" security 2>/dev/null || echo none)
  type=$(ss_get_query_param "$qs" type 2>/dev/null || echo tcp)
  # Normalize alias network names used by clients / OpenFlux
  case "$type" in
  h2 | http) type="h2" ;;
  httpupgrade | http_upgrade) type="httpupgrade" ;;
  xhttp | splithttp) type="xhttp" ;;
  esac
  flow=$(ss_get_query_param "$qs" flow 2>/dev/null || echo "")
  sni=$(ss_get_query_param "$qs" sni 2>/dev/null || echo "")
  fp=$(ss_get_query_param "$qs" fp 2>/dev/null || echo chrome)
  pbk=$(ss_get_query_param "$qs" pbk 2>/dev/null || echo "")
  sid=$(ss_get_query_param "$qs" sid 2>/dev/null || echo "")
  spx=$(ss_get_query_param "$qs" spx 2>/dev/null || echo "")
  path=$(ss_get_query_param "$qs" path 2>/dev/null || echo "")
  host_header=$(ss_get_query_param "$qs" host 2>/dev/null || echo "")
  mode=$(ss_get_query_param "$qs" mode 2>/dev/null || echo "")
  service_name=$(ss_get_query_param "$qs" serviceName 2>/dev/null || ss_get_query_param "$qs" servicename 2>/dev/null || echo "")
  alpn=$(ss_get_query_param "$qs" alpn 2>/dev/null || echo "")

  jq -nc \
    --arg tag "${name:-stealthsurf}" \
    --arg address "$host" \
    --argjson port "${port:-443}" \
    --arg id "$uuid" \
    --arg encryption "${encryption:-none}" \
    --arg flow "$flow" \
    --arg security "$security" \
    --arg network "$type" \
    --arg sni "$sni" \
    --arg fp "$fp" \
    --arg pbk "$pbk" \
    --arg sid "$sid" \
    --arg spx "$spx" \
    --arg path "$path" \
    --arg host_header "$host_header" \
    --arg mode "$mode" \
    --arg service_name "$service_name" \
    --arg alpn "$alpn" '
    {
      tag: $tag,
      protocol: "vless",
      settings: {
        vnext: [{
          address: $address,
          port: $port,
          users: [{
            id: $id,
            encryption: $encryption,
            flow: (if $flow == "" then null else $flow end)
          } | with_entries(select(.value != null))]
        }]
      },
      streamSettings: (
        {
          network: $network,
          security: $security
        }
        + (if $security == "reality" then {
            realitySettings: {
              serverName: (if $sni == "" then $address else $sni end),
              fingerprint: $fp,
              publicKey: $pbk,
              shortId: $sid,
              spiderX: (if $spx == "" then "/" else $spx end)
            }
          } elif $security == "tls" then {
            tlsSettings: {
              serverName: (if $sni == "" then $address else $sni end),
              fingerprint: $fp,
              allowInsecure: false,
              alpn: (if $alpn == "" then null else ($alpn | split(",")) end)
            } | with_entries(select(.value != null))
          } else {} end)
        + (if $network == "ws" then {
            wsSettings: {
              path: (if $path == "" then "/" else $path end),
              headers: (if $host_header == "" then {} else {Host: $host_header} end)
            }
          } elif $network == "grpc" then {
            grpcSettings: {
              serviceName: (if $service_name != "" then $service_name elif $path == "" then "" else $path end)
            }
          } elif $network == "h2" then {
            httpSettings: {
              path: (if $path == "" then "/" else $path end),
              host: (if $host_header == "" then [] else [$host_header] end)
            }
          } elif $network == "httpupgrade" then {
            httpupgradeSettings: {
              path: (if $path == "" then "/" else $path end),
              host: $host_header
            }
          } elif $network == "xhttp" or $network == "splithttp" then {
            xhttpSettings: {
              path: (if $path == "" then "/" else $path end),
              host: $host_header,
              mode: (if $mode == "" then "auto" else $mode end)
            }
          } else {} end)
      )
    }'
}

ss_parse_trojan() {
  local link="$1"
  local rest password hostport host port qs name sni type security

  rest="${link#trojan://}"
  name=""
  case "$rest" in
  *#*)
    name=$(ss_urldecode "${rest#*#}")
    rest="${rest%%#*}"
    ;;
  esac
  password="${rest%%@*}"
  rest="${rest#*@}"
  qs=""
  case "$rest" in
  *\?*)
    qs="${rest#*\?}"
    hostport="${rest%%\?*}"
    ;;
  *) hostport="$rest" ;;
  esac
  case "$hostport" in
  *:*)
    host="${hostport%:*}"
    port="${hostport##*:}"
    ;;
  *)
    host="$hostport"
    port="443"
    ;;
  esac
  case "$port" in
  '' | *[!0-9]*) port="443" ;;
  esac
  sni=$(ss_get_query_param "$qs" sni 2>/dev/null || echo "$host")
  type=$(ss_get_query_param "$qs" type 2>/dev/null || echo tcp)
  security=$(ss_get_query_param "$qs" security 2>/dev/null || echo tls)

  jq -nc \
    --arg tag "${name:-stealthsurf}" \
    --arg address "$host" \
    --argjson port "${port:-443}" \
    --arg password "$password" \
    --arg sni "$sni" \
    --arg network "$type" \
    --arg security "$security" '
    {
      tag: $tag,
      protocol: "trojan",
      settings: {
        servers: [{ address: $address, port: $port, password: $password }]
      },
      streamSettings: {
        network: $network,
        security: $security,
        tlsSettings: {
          serverName: $sni,
          allowInsecure: false
        }
      }
    }'
}

ss_parse_shadowsocks() {
  # Supports ss://METHOD:PASSWORD@HOST:PORT#name and base64 userinfo forms used by SS2022
  local link="$1"
  local rest userinfo hostport host port method password name decoded

  rest="${link#ss://}"
  name=""
  case "$rest" in
  *#*)
    name=$(ss_urldecode "${rest#*#}")
    rest="${rest%%#*}"
    ;;
  esac
  case "$rest" in
  *\?*) rest="${rest%%\?*}" ;;
  esac

  case "$rest" in
  *@*)
    userinfo="${rest%%@*}"
    hostport="${rest#*@}"
    case "$userinfo" in
    *:*)
      method="${userinfo%%:*}"
      password="${userinfo#*:}"
      ;;
    *)
      decoded=$(printf '%s' "$userinfo" | tr '_-' '/+' | awk '{
        l=length($0); m=(4-l%4)%4;
        if(m==1) $0=$0"="; else if(m==2) $0=$0"==";
        print
      }' | (base64 -d 2>/dev/null || openssl base64 -d -A 2>/dev/null))
      method="${decoded%%:*}"
      password="${decoded#*:}"
      ;;
    esac
    ;;
  *)
    decoded=$(printf '%s' "$rest" | tr '_-' '/+' | awk '{
      l=length($0); m=(4-l%4)%4;
      if(m==1) $0=$0"="; else if(m==2) $0=$0"==";
      print
    }' | (base64 -d 2>/dev/null || openssl base64 -d -A 2>/dev/null))
    userinfo="${decoded%%@*}"
    hostport="${decoded#*@}"
    method="${userinfo%%:*}"
    password="${userinfo#*:}"
    ;;
  esac

  case "$hostport" in
  *:*)
    host="${hostport%:*}"
    port="${hostport##*:}"
    ;;
  *)
    host="$hostport"
    port="443"
    ;;
  esac
  case "$port" in
  '' | *[!0-9]*) port="443" ;;
  esac

  jq -nc \
    --arg tag "${name:-stealthsurf}" \
    --arg address "$host" \
    --argjson port "${port:-443}" \
    --arg method "$method" \
    --arg password "$password" '
    {
      tag: $tag,
      protocol: "shadowsocks",
      settings: {
        servers: [{
          address: $address,
          port: $port,
          method: $method,
          password: $password
        }]
      }
    }'
}

ss_parse_link_to_outbound() {
  local link="$1"
  case "$link" in
  vless://*) ss_parse_vless "$link" ;;
  trojan://*) ss_parse_trojan "$link" ;;
  ss://*) ss_parse_shadowsocks "$link" ;;
  http://* | socks5://* | socks://*)
    ss_parse_http_socks_subconfig "$link" "proxy"
    ;;
  hy2://* | hysteria2://* | hysteria://*)
    # Caller should use protocols.sh for hysteria runtime; provide socks bridge hint
    ss_error "Hysteria2 links need hysteria runtime (ss_apply_protocol_config)"
    return 1
    ;;
  *)
    if printf '%s' "$link" | grep -q '\[Interface\]'; then
      ss_error "WireGuard/AWG blobs need wg/awg runtime (ss_apply_protocol_config)"
      return 1
    fi
    ss_error "Unsupported connection_url scheme"
    return 1
    ;;
  esac
}

ss_build_inbounds_json() {
  local mode
  mode=$(ss_fw_detect_mode 2>/dev/null || echo "${SS_MODE:-proxy}")
  jq -nc \
    --argjson socks "${SS_SOCKS_PORT:-10808}" \
    --argjson http "${SS_HTTP_PORT:-10809}" \
    --argjson tproxy "${SS_TPROXY_PORT:-10810}" \
    --argjson redirect "${SS_REDIRECT_PORT:-10811}" \
    --argjson dns "${SS_DNS_PORT:-5353}" \
    --arg mode "$mode" \
    --arg dns_mode "${SS_DNS_MODE:-OFF}" '
    [
      {
        tag: "socks-in",
        listen: "0.0.0.0",
        port: $socks,
        protocol: "socks",
        settings: { udp: true },
        sniffing: { enabled: true, destOverride: ["http","tls","quic"] }
      },
      {
        tag: "http-in",
        listen: "0.0.0.0",
        port: $http,
        protocol: "http",
        sniffing: { enabled: true, destOverride: ["http","tls"] }
      }
    ]
    + (if $mode == "tproxy" then [{
        tag: "tproxy-in",
        listen: "0.0.0.0",
        port: $tproxy,
        protocol: "dokodemo-door",
        settings: { network: "tcp,udp", followRedirect: true },
        sniffing: { enabled: true, destOverride: ["http","tls","quic"], routeOnly: true },
        streamSettings: { sockopt: { tproxy: "tproxy" } }
      }] elif $mode == "redirect" then [{
        tag: "redirect-in",
        listen: "0.0.0.0",
        port: $redirect,
        protocol: "dokodemo-door",
        settings: { network: "tcp", followRedirect: true },
        sniffing: { enabled: true, destOverride: ["http","tls"], routeOnly: true }
      }] else [] end)
    + (if $dns_mode == "REDIRECT" then [{
        tag: "dns-in",
        listen: "0.0.0.0",
        port: $dns,
        protocol: "dokodemo-door",
        settings: { address: "1.1.1.1", port: 53, network: "tcp,udp" }
      }] else [] end)
  '
}

ss_build_xray_config() {
  # Legacy single-outbound builder (still used by apply <id> convenience)
  local outbound_json="$1"
  local socks_port="${SS_SOCKS_PORT:-10808}"
  local http_port="${SS_HTTP_PORT:-10809}"
  local inbounds default_tag

  # Tag as proxy for simple routing
  outbound_json=$(printf '%s' "$outbound_json" | jq '.tag = (if .tag == null or .tag == "" then "proxy" else .tag end)')
  default_tag=$(printf '%s' "$outbound_json" | jq -r '.tag')
  inbounds=$(ss_build_inbounds_json)

  jq -nc \
    --argjson outbound "$outbound_json" \
    --argjson inbounds "$inbounds" \
    --arg def "$default_tag" \
    --arg access "$XRAY_ACCESS_LOG" \
    --arg error "$XRAY_ERROR_LOG" '
    {
      log: { loglevel: "warning", access: $access, error: $error },
      inbounds: $inbounds,
      outbounds: [
        $outbound,
        { tag: "direct", protocol: "freedom" },
        { tag: "block", protocol: "blackhole" }
      ],
      routing: {
        domainStrategy: "AsIs",
        rules: [
          { type: "field", outboundTag: "direct", ip: ["geoip:private"] },
          { type: "field", outboundTag: $def, network: "tcp,udp" }
        ]
      }
    }'
}

ss_build_xray_config_multi() {
  # Full multi-outbound + routing from catalog/rules
  local outbounds inbounds rules default_tag bridges
  ss_collect_endpoints
  ss_routing_validate || return 1

  outbounds=$(ss_build_multi_outbounds) || return 1
  # Merge hysteria SOCKS bridges only if tag not already present (ss_outbound_from_entry
  # already embeds the bridge outbound — avoid duplicate tags that break Xray)
  for bridges in "$ADDON_DATA_DIR"/bridge-ss-*.json; do
    [ -f "$bridges" ] || continue
    outbounds=$(printf '%s' "$outbounds" | jq --slurpfile b "$bridges" '
      ($b[0].tag // "") as $t |
      if ($t == "") or any(.[]; .tag == $t) then . else . + $b end
    ') || return 1
  done
  outbounds=$(printf '%s' "$outbounds" | jq 'unique_by(.tag)') || return 1

  inbounds=$(ss_build_inbounds_json)
  rules=$(ss_build_routing_rules_json)
  default_tag="${SS_DEFAULT_OUTBOUND:-direct}"
  if [ -f "$SS_OUTBOUNDS_FILE" ]; then
    default_tag=$(jq -r '.default // "direct"' "$SS_OUTBOUNDS_FILE")
  fi

  # Ensure default exists in outbounds; else fall back to first ss-* or direct
  if ! printf '%s' "$outbounds" | jq -e --arg t "$default_tag" 'any(.[]; .tag == $t)' >/dev/null 2>&1; then
    default_tag=$(printf '%s' "$outbounds" | jq -r '[.[] | select(.tag|startswith("ss-"))][0].tag // "direct"')
  fi

  jq -nc \
    --argjson outbounds "$outbounds" \
    --argjson inbounds "$inbounds" \
    --argjson rules "$rules" \
    --arg def "$default_tag" \
    --arg access "$XRAY_ACCESS_LOG" \
    --arg error "$XRAY_ERROR_LOG" \
    --arg strategy "$(jq -r '.domainStrategy // "AsIs"' "$SS_ROUTING_FILE" 2>/dev/null || echo AsIs)" '
    {
      log: { loglevel: "warning", access: $access, error: $error },
      inbounds: $inbounds,
      outbounds: $outbounds,
      routing: {
        domainStrategy: $strategy,
        rules: ($rules + [{ type: "field", outboundTag: $def, network: "tcp,udp" }])
      }
    }'
}
