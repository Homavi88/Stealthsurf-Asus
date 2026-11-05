#!/bin/sh
# Multi-runtime: Hysteria2, WireGuard, AmneziaWG, OpenFlux, HTTP/SOCKS subconfigs

HY2_PIDFILE="/var/run/stealthsurf-hysteria.pid"
HY2_CONF="/opt/etc/stealthsurf-hysteria.yaml"
WG_CONF_DIR="/opt/etc/stealthsurf-wg"
WG_IFACE_PREFIX="sswg"

ss_parse_hysteria2() {
  # hy2://auth@host:port?insecure=1&sni=...#name → YAML for hysteria client
  local link="$1"
  local config_id="$2"
  local rest auth hostport host port qs sni insecure obfs

  rest="${link#*://}"
  case "$rest" in *#*) rest="${rest%%#*}" ;; esac
  auth="${rest%%@*}"
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
  insecure=$(ss_get_query_param "$qs" insecure 2>/dev/null || echo "0")
  obfs=$(ss_get_query_param "$qs" obfs 2>/dev/null || echo "")

  cat <<EOF
server: ${host}:${port}
auth: ${auth}
tls:
  sni: ${sni}
  insecure: $([ "$insecure" = "1" ] && echo true || echo false)
bandwidth:
  up: 100 mbps
  down: 100 mbps
socks5:
  listen: 127.0.0.1:$((18000 + ${config_id:-0}))
http:
  listen: 127.0.0.1:$((19000 + ${config_id:-0}))
EOF
}

ss_start_hysteria() {
  local config_id="$1"
  local link="$2"
  local conf pidfile
  conf="${HY2_CONF}.${config_id}"
  pidfile="${HY2_PIDFILE}.${config_id}"

  if ! ss_protocol_supported_on_router hysteria2; then
    ss_error "Hysteria2 client not installed (place binary at /opt/sbin/hysteria)"
    return 1
  fi
  [ -x "$HYSTERIA_BIN" ] || HYSTERIA_BIN=$(command -v hysteria)

  ss_parse_hysteria2 "$link" "$config_id" >"$conf"
  if [ -f "$pidfile" ]; then
    kill "$(cat "$pidfile")" 2>/dev/null || true
    rm -f "$pidfile"
  fi
  "$HYSTERIA_BIN" client -c "$conf" >/dev/null 2>&1 &
  echo $! >"$pidfile"
  sleep 1
  if kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    ss_ok "Hysteria2 started for config $config_id (socks 127.0.0.1:$((18000 + config_id)))"
    # Register local socks bridge as Xray outbound helper file
    jq -nc --arg tag "ss-$config_id" --argjson port $((18000 + config_id)) '
      {tag:$tag, protocol:"socks", settings:{servers:[{address:"127.0.0.1", port:$port}]}}
    ' >"$ADDON_DATA_DIR/bridge-ss-${config_id}.json"
    return 0
  fi
  ss_error "Hysteria2 failed to start for config $config_id"
  rm -f "$pidfile"
  return 1
}

ss_stop_hysteria_all() {
  local f
  for f in /var/run/stealthsurf-hysteria.pid*; do
    [ -f "$f" ] || continue
    kill "$(cat "$f")" 2>/dev/null || true
    rm -f "$f"
  done
  rm -f "$ADDON_DATA_DIR"/bridge-ss-*.json 2>/dev/null
}

ss_parse_wg_ini() {
  # Dump WireGuard/AWG INI blob to interface config file
  local blob="$1"
  local outfile="$2"
  printf '%s\n' "$blob" >"$outfile"
}

ss_start_wg() {
  local config_id="$1"
  local blob="$2"
  local runtime="${3:-wg}" # wg | awg
  local iface conf bin
  iface="${WG_IFACE_PREFIX}${config_id}"
  mkdir -p "$WG_CONF_DIR"
  conf="$WG_CONF_DIR/${iface}.conf"
  ss_parse_wg_ini "$blob" "$conf"

  if [ "$runtime" = "awg" ]; then
    if ! ss_protocol_supported_on_router amnezia-wg-2; then
      ss_error "AmneziaWG (awg) not installed on this router"
      return 1
    fi
    bin=$(command -v awg-quick 2>/dev/null || echo awg-quick)
  else
    if ! ss_protocol_supported_on_router wg; then
      ss_error "WireGuard (wg) not available on this router"
      return 1
    fi
    bin=$(command -v wg-quick 2>/dev/null || echo wg-quick)
  fi

  # Down previous
  $bin down "$conf" 2>/dev/null || true
  if $bin up "$conf" 2>/dev/null; then
    ss_ok "$runtime interface $iface is up"
    echo "$iface" >"$WG_CONF_DIR/${config_id}.iface"
    return 0
  fi
  ss_error "Failed to bring up $runtime for config $config_id"
  return 1
}

ss_stop_wg_all() {
  local f iface
  for f in "$WG_CONF_DIR"/*.iface; do
    [ -f "$f" ] || continue
    iface=$(cat "$f")
    wg-quick down "$WG_CONF_DIR/${iface}.conf" 2>/dev/null || true
    awg-quick down "$WG_CONF_DIR/${iface}.conf" 2>/dev/null || true
    rm -f "$f"
  done
}

ss_parse_http_socks_subconfig() {
  # StealthSurf may return http://user:pass@host:port or socks5://...
  local link="$1"
  local tag="$2"
  local scheme rest userpass hostport host port user pass

  case "$link" in
  http://*)
    scheme=http
    rest="${link#http://}"
    ;;
  socks5://* | socks://*)
    scheme=socks
    rest="${link#*://}"
    ;;
  *)
    ss_error "Not an HTTP/SOCKS URL"
    return 1
    ;;
  esac

  user=""
  pass=""
  case "$rest" in
  *@*)
    userpass="${rest%%@*}"
    hostport="${rest#*@}"
    user="${userpass%%:*}"
    pass="${userpass#*:}"
    ;;
  *) hostport="$rest" ;;
  esac
  host="${hostport%:*}"
  port="${hostport##*:}"

  jq -nc \
    --arg tag "$tag" \
    --arg protocol "$scheme" \
    --arg address "$host" \
    --argjson port "${port:-1080}" \
    --arg user "$user" \
    --arg pass "$pass" '
    {
      tag: $tag,
      protocol: $protocol,
      settings: {
        servers: [
          {
            address: $address,
            port: $port
          }
          + (if $user != "" then {users:[{user:$user, pass:$pass}]} else {} end)
        ]
      }
    }'
}

ss_apply_protocol_config() {
  # Unified apply for one config id based on protocol
  local config_id="$1"
  local entry link proto runtime
  entry=$(ss_cache_get_config "$config_id") || return 1
  proto=$(printf '%s' "$entry" | jq -r '.protocol // "vless"')
  link=$(printf '%s' "$entry" | jq -r '.connection_url // empty')
  runtime=$(ss_protocol_runtime "$proto")

  case "$runtime" in
  xray)
    # Handled by multi-outbound Xray builder
    return 0
    ;;
  hysteria)
    [ -n "$link" ] || return 1
    ss_start_hysteria "$config_id" "$link"
    ;;
  wg)
    [ -n "$link" ] || return 1
    ss_start_wg "$config_id" "$link" wg
    ;;
  awg)
    [ -n "$link" ] || return 1
    ss_start_wg "$config_id" "$link" awg
    ;;
  openflux)
    ss_error "OpenFlux is not yet available on this router build (status: in development)"
    return 1
    ;;
  *)
    ss_error "Unsupported protocol: $proto"
    return 1
    ;;
  esac
}

ss_protocol_status_matrix() {
  jq -nc \
    --argjson xray "$(ss_protocol_supported_on_router vless && echo true || echo false)" \
    --argjson hy2 "$(ss_protocol_supported_on_router hysteria2 && echo true || echo false)" \
    --argjson wg "$(ss_protocol_supported_on_router wg && echo true || echo false)" \
    --argjson awg "$(ss_protocol_supported_on_router amnezia-wg-2 && echo true || echo false)" \
    '{
      vless: {runtime:"xray", supported:$xray},
      "vless-2410": {runtime:"xray", supported:$xray},
      trojan: {runtime:"xray", supported:$xray},
      "trojan-2901": {runtime:"xray", supported:$xray},
      "shadowsocks-2022": {runtime:"xray", supported:$xray},
      hysteria2: {runtime:"hysteria", supported:$hy2, status: (if $hy2 then "ready" else "needs /opt/sbin/hysteria" end)},
      wg: {runtime:"wg", supported:$wg, status: (if $wg then "ready" else "needs WireGuard" end)},
      "amnezia-wg-2": {runtime:"awg", supported:$awg, status: (if $awg then "ready" else "needs AmneziaWG" end)},
      openflux: {runtime:"openflux", supported:false, status:"in development"},
      http: {runtime:"xray", supported:$xray},
      socks5: {runtime:"xray", supported:$xray}
    }'
}

ss_stop_all_runtimes() {
  ss_stop_hysteria_all
  ss_stop_wg_all
}
