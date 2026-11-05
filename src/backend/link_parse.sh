#!/bin/sh

# Convert StealthSurf connection_url (share link) into an Xray outbound object (JSON).

ss_parse_vless() {
  local link="$1"
  local rest uuid hostport host port qs name
  local encryption security type flow sni fp pbk sid spx path host_header

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
  flow=$(ss_get_query_param "$qs" flow 2>/dev/null || echo "")
  sni=$(ss_get_query_param "$qs" sni 2>/dev/null || echo "")
  fp=$(ss_get_query_param "$qs" fp 2>/dev/null || echo chrome)
  pbk=$(ss_get_query_param "$qs" pbk 2>/dev/null || echo "")
  sid=$(ss_get_query_param "$qs" sid 2>/dev/null || echo "")
  spx=$(ss_get_query_param "$qs" spx 2>/dev/null || echo "")
  path=$(ss_get_query_param "$qs" path 2>/dev/null || echo "")
  host_header=$(ss_get_query_param "$qs" host 2>/dev/null || echo "")

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
    --arg host_header "$host_header" '
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
              allowInsecure: false
            }
          } else {} end)
        + (if $network == "ws" then {
            wsSettings: {
              path: (if $path == "" then "/" else $path end),
              headers: (if $host_header == "" then {} else {Host: $host_header} end)
            }
          } elif $network == "grpc" then {
            grpcSettings: {
              serviceName: (if $path == "" then "" else $path end)
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
  host="${hostport%:*}"
  port="${hostport##*:}"
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

  host="${hostport%:*}"
  port="${hostport##*:}"

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
  hy2://* | hysteria2://* | hysteria://*)
    ss_error "Hysteria2 is planned after MVP (needs hysteria client, not only Xray)"
    return 1
    ;;
  *)
    # WireGuard INI blob from StealthSurf
    if printf '%s' "$link" | grep -q '\[Interface\]'; then
      ss_error "WireGuard/AWG apply is planned after MVP"
      return 1
    fi
    ss_error "Unsupported connection_url scheme"
    return 1
    ;;
  esac
}

ss_build_xray_config() {
  local outbound_json="$1"
  local socks_port="${SS_SOCKS_PORT:-10808}"
  local http_port="${SS_HTTP_PORT:-10809}"

  jq -nc \
    --argjson outbound "$outbound_json" \
    --argjson socks "$socks_port" \
    --argjson http "$http_port" '
    {
      log: { loglevel: "warning" },
      inbounds: [
        {
          tag: "socks-in",
          listen: "0.0.0.0",
          port: $socks,
          protocol: "socks",
          settings: { udp: true }
        },
        {
          tag: "http-in",
          listen: "0.0.0.0",
          port: $http,
          protocol: "http"
        }
      ],
      outbounds: [
        $outbound,
        { tag: "direct", protocol: "freedom" },
        { tag: "block", protocol: "blackhole" }
      ],
      routing: {
        domainStrategy: "AsIs",
        rules: [
          { type: "field", outboundTag: "direct", ip: ["geoip:private"] }
        ]
      }
    }'
}
