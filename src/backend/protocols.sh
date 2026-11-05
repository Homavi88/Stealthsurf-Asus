#!/bin/sh
# Multi-runtime for all StealthSurf API protocols:
#   vless, vless-2410, trojan, trojan-2901, shadowsocks-2022  → Xray
#   openflux (via xray_config)                               → Xray
#   wg                                                       → Xray wireguard outbound (preferred)
#   amnezia-wg-2                                             → awg-quick (+ optional policy)
#   hysteria2                                                → hysteria client + local SOCKS bridge
#   http / socks5                                            → Xray outbound

HY2_PIDFILE="/var/run/stealthsurf-hysteria.pid"
HY2_CONF="/opt/etc/stealthsurf-hysteria.yaml"
WG_CONF_DIR="/opt/etc/stealthsurf-wg"
WG_IFACE_PREFIX="sswg"
HYSTERIA_RELEASE_API="https://api.github.com/repos/apernet/hysteria/releases/latest"

# ---------- Xray JSON from API (preferred over share-link parse) ----------

ss_outbound_from_xray_config() {
  # Extract first non-freedom/blackhole outbound from API xray_config JSON string
  local xray_json="$1"
  local tag="$2"
  local parsed
  # xray_config may itself be a JSON string (escaped) or raw object
  parsed=$(printf '%s' "$xray_json" | jq -c '
    (if type == "string" then (fromjson? // .) else . end) as $root |
    ($root.outbounds // $root.outbound // (if $root.protocol then [$root] else [] end)) as $obs |
    ($obs | map(select(.protocol != "freedom" and .protocol != "blackhole" and .protocol != "dns")) | first) // empty
  ' 2>/dev/null)
  [ -n "$parsed" ] && [ "$parsed" != "null" ] || return 1
  if [ -n "$tag" ]; then
    printf '%s' "$parsed" | jq --arg tag "$tag" '.tag = $tag'
  else
    printf '%s' "$parsed"
  fi
}

# ---------- WireGuard INI → Xray wireguard outbound ----------

ss_wg_ini_field() {
  # ss_wg_ini_field <blob> <Section> <Key>
  local blob="$1" section="$2" key="$3"
  printf '%s\n' "$blob" | awk -v sec="$section" -v key="$key" '
    BEGIN{ins=0}
    /^\[/{ins=0}
    $0=="["sec"]"{ins=1; next}
    ins {
      # Allow "Key = value" with optional spaces; match key before first =
      line=$0
      gsub(/\r/,"",line)
      if (match(line, /^[ \t]*[^=]+[ \t]*=/)) {
        k=line
        sub(/[ \t]*=.*/, "", k)
        gsub(/^[ \t]+|[ \t]+$/, "", k)
        if (k==key) {
          sub(/^[^=]*=[ \t]*/, "", line)
          gsub(/[ \t]+$/, "", line)
          print line
          exit
        }
      }
    }
  '
}

ss_wg_ini_to_xray_outbound() {
  # Convert StealthSurf WG connection_url (INI) to Xray wireguard outbound
  local blob="$1"
  local tag="$2"
  local priv addr dns mtu peer_pub endpoint allowed psk keepalive

  priv=$(ss_wg_ini_field "$blob" "Interface" "PrivateKey")
  addr=$(ss_wg_ini_field "$blob" "Interface" "Address" | cut -d, -f1 | tr -d ' ')
  dns=$(ss_wg_ini_field "$blob" "Interface" "DNS" | cut -d, -f1 | tr -d ' ')
  mtu=$(ss_wg_ini_field "$blob" "Interface" "MTU")
  peer_pub=$(ss_wg_ini_field "$blob" "Peer" "PublicKey")
  endpoint=$(ss_wg_ini_field "$blob" "Peer" "Endpoint")
  allowed=$(ss_wg_ini_field "$blob" "Peer" "AllowedIPs")
  psk=$(ss_wg_ini_field "$blob" "Peer" "PresharedKey")
  keepalive=$(ss_wg_ini_field "$blob" "Peer" "PersistentKeepalive")

  [ -n "$priv" ] && [ -n "$peer_pub" ] && [ -n "$endpoint" ] || {
    ss_error "WG INI missing PrivateKey/PublicKey/Endpoint"
    return 1
  }
  [ -n "$addr" ] || addr="10.0.0.2/32"
  [ -n "$allowed" ] || allowed="0.0.0.0/0, ::/0"
  [ -n "$mtu" ] || mtu="1280"
  # Strip non-digits from MTU so --arg + tonumber never breaks jq
  mtu=$(printf '%s' "$mtu" | tr -cd '0-9')
  [ -n "$mtu" ] || mtu="1280"

  jq -nc \
    --arg tag "${tag:-wg}" \
    --arg secretKey "$priv" \
    --arg address "$addr" \
    --arg publicKey "$peer_pub" \
    --arg endpoint "$endpoint" \
    --arg allowedIPs "$allowed" \
    --arg psk "${psk:-}" \
    --arg mtu "$mtu" \
    --arg keepalive "${keepalive:-25}" '
    {
      tag: $tag,
      protocol: "wireguard",
      settings: (
        {
          secretKey: $secretKey,
          address: [$address],
          mtu: (try ($mtu|tonumber) catch 1280),
          peers: [
            {
              publicKey: $publicKey,
              endpoint: $endpoint,
              keepAlive: (try ($keepalive|tonumber) catch 25),
              allowedIPs: ($allowedIPs | split(",") | map(gsub("^\\s+|\\s+$";"")) | map(select(. != "")))
            }
            + (if $psk != "" then {preSharedKey: $psk} else {} end)
          ]
        }
      )
    }'
}

ss_awg_json_to_ini() {
  # Best-effort: if API gives awg_config JSON with connection-like fields, pass through
  # Prefer connection_url INI when present; awg_config is often server-side params.
  local awg_json="$1"
  printf '%s' "$awg_json" | jq -r '
    if type == "string" then (fromjson? // .) else . end |
    if .Interface and .Peer then
      # already structured
      empty
    elif .config then .config
    elif .ini then .ini
    elif .connection_url then .connection_url
    else empty end
  ' 2>/dev/null
}

# ---------- Hysteria2 ----------

ss_parse_hysteria2() {
  local link="$1"
  local config_id="$2"
  local rest auth hostport host port qs sni insecure obfs obfs_password salamander

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
  obfs_password=$(ss_get_query_param "$qs" obfs-password 2>/dev/null || ss_get_query_param "$qs" obfs_password 2>/dev/null || echo "")
  salamander=$(ss_get_query_param "$qs" salamander 2>/dev/null || echo "")

  # StealthSurf use_salamander → often obfs=salamander
  if [ -z "$obfs" ] && [ -n "$salamander" ]; then
    obfs="salamander"
    [ -z "$obfs_password" ] && obfs_password="$salamander"
  fi

  {
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
    if [ -n "$obfs" ]; then
      cat <<EOF
obfs:
  type: ${obfs}
  salamander:
    password: ${obfs_password:-${auth}}
EOF
    fi
  }
}

ss_ensure_hysteria() {
  if [ -x "$HYSTERIA_BIN" ] || command -v hysteria >/dev/null 2>&1; then
    [ -x "$HYSTERIA_BIN" ] || HYSTERIA_BIN=$(command -v hysteria)
    return 0
  fi
  ss_info "Hysteria binary missing — trying download…"
  local arch asset tmpdir name
  case "$(uname -m)" in
  aarch64 | arm64) name="hysteria-linux-arm64" ;;
  armv7* | armv6* | arm) name="hysteria-linux-arm" ;;
  x86_64 | amd64) name="hysteria-linux-amd64" ;;
  *) name="hysteria-linux-arm64" ;;
  esac
  tmpdir="$ADDON_TMP_DIR/hy2-dl.$$"
  mkdir -p "$tmpdir"
  asset=$(curl -fsSL -H "Accept: application/vnd.github+json" \
    -H "User-Agent: stealthsurf-merlin/$ADDON_VERSION" \
    "$HYSTERIA_RELEASE_API" 2>/dev/null |
    jq -r --arg n "$name" '.assets[] | select(.name == $n or .name == ($n + ".tar.gz") or (.name|test($n))) | .browser_download_url' | head -1)
  if [ -z "$asset" ]; then
    ss_error "Cannot resolve Hysteria release asset for $name"
    rm -rf "$tmpdir"
    return 1
  fi
  if ! curl -fsSL -o "$tmpdir/hy" "$asset"; then
    ss_error "Hysteria download failed"
    rm -rf "$tmpdir"
    return 1
  fi
  # May be raw binary or archive
  if file "$tmpdir/hy" 2>/dev/null | grep -qi 'gzip\|tar'; then
    mv "$tmpdir/hy" "$tmpdir/hy.tgz"
    tar -xzf "$tmpdir/hy.tgz" -C "$tmpdir" 2>/dev/null || true
    find "$tmpdir" -type f -name 'hysteria*' ! -name '*.tgz' | head -1 | while read -r f; do
      mv -f "$f" /opt/sbin/hysteria
    done
  else
    mv -f "$tmpdir/hy" /opt/sbin/hysteria
  fi
  chmod 0755 /opt/sbin/hysteria 2>/dev/null || true
  HYSTERIA_BIN="/opt/sbin/hysteria"
  rm -rf "$tmpdir"
  [ -x "$HYSTERIA_BIN" ] || {
    ss_error "Hysteria install failed"
    return 1
  }
  ss_ok "Hysteria installed: $($HYSTERIA_BIN version 2>/dev/null | head -1)"
}

ss_start_hysteria() {
  local config_id="$1"
  local link="$2"
  local conf pidfile
  conf="${HY2_CONF}.${config_id}"
  pidfile="${HY2_PIDFILE}.${config_id}"

  ss_ensure_hysteria || return 1
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
}

# ---------- Native WG/AWG interface (AmneziaWG / fallback) ----------

ss_parse_wg_ini() {
  local blob="$1"
  local outfile="$2"
  # Ensure Interface has a Name for wg-quick on Merlin
  if ! printf '%s' "$blob" | grep -q '^Name\s*='; then
    local iface
    iface=$(basename "$outfile" .conf)
    {
      echo "[Interface]"
      echo "Name = $iface"
      printf '%s\n' "$blob" | awk 'BEGIN{skip=0} /^\[Interface\]/{skip=1; next} /^\[/{skip=0} !skip || !/^Name/'
    } >"$outfile"
  else
    printf '%s\n' "$blob" >"$outfile"
  fi
}

ss_start_wg_iface() {
  local config_id="$1"
  local blob="$2"
  local runtime="${3:-wg}"
  local iface conf bin
  iface="${WG_IFACE_PREFIX}${config_id}"
  mkdir -p "$WG_CONF_DIR"
  conf="$WG_CONF_DIR/${iface}.conf"
  ss_parse_wg_ini "$blob" "$conf"

  if [ "$runtime" = "awg" ]; then
    if ! ss_protocol_supported_on_router amnezia-wg-2; then
      ss_error "AmneziaWG (awg) not installed — install awg/awg-quick on the router"
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

  $bin down "$conf" 2>/dev/null || true
  if $bin up "$conf" 2>/dev/null; then
    ss_ok "$runtime interface $iface is up"
    echo "$iface" >"$WG_CONF_DIR/${config_id}.iface"
    # For sole VPN use: optional default route via interface is left to user/policy;
    # multi-outbound prefers Xray wireguard outbound instead.
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

# ---------- Unified: config cache entry → Xray outbound (or side runtime) ----------

ss_outbound_from_entry() {
  # stdin unused; args: entry_json [tag]
  # Prints Xray outbound JSON. For hysteria/awg starts side runtime and writes bridge file.
  local entry="$1"
  local tag="$2"
  local proto link xray_cfg awg_cfg runtime id

  [ -n "$entry" ] && [ "$entry" != "null" ] || return 1
  id=$(printf '%s' "$entry" | jq -r '.id // empty')
  proto=$(printf '%s' "$entry" | jq -r '.protocol // "vless"')
  link=$(printf '%s' "$entry" | jq -r '.connection_url // empty')
  xray_cfg=$(printf '%s' "$entry" | jq -r '.xray_config // empty')
  awg_cfg=$(printf '%s' "$entry" | jq -r '.awg_config // empty')
  [ -n "$tag" ] || tag=$(ss_outbound_tag "$id")
  runtime=$(ss_protocol_runtime "$proto")

  # 1) Prefer official xray_config (covers openflux, xhttp/grpc extended, etc.)
  if [ -n "$xray_cfg" ] && [ "$xray_cfg" != "null" ]; then
    if ss_outbound_from_xray_config "$xray_cfg" "$tag"; then
      ss_activity "protocol.xray_config" "id=$id proto=$proto tag=$tag"
      return 0
    fi
    ss_warn "xray_config present but could not extract outbound for id=$id"
  fi

  case "$runtime" in
  xray | openflux)
    # openflux without usable xray_config: try connection_url schemes
    if [ "$runtime" = "openflux" ] && [ -z "$xray_cfg" ]; then
      ss_warn "openflux id=$id: no xray_config — trying connection_url"
    fi
    [ -n "$link" ] || {
      ss_error "Config $id has empty connection_url and no xray_config"
      return 1
    }
    case "$link" in
    vless://* | trojan://* | ss://* | http://* | socks5://* | socks://*)
      ss_parse_link_to_outbound "$link" | jq --arg tag "$tag" '.tag = $tag'
      ;;
    *)
      # Maybe raw JSON outbound
      if printf '%s' "$link" | jq -e '.protocol' >/dev/null 2>&1; then
        printf '%s' "$link" | jq --arg tag "$tag" '.tag = $tag'
      else
        ss_error "Unsupported link for proto=$proto id=$id"
        return 1
      fi
      ;;
    esac
    ;;
  hysteria)
    [ -n "$link" ] || return 1
    ss_start_hysteria "$id" "$link" || return 1
    cat "$ADDON_DATA_DIR/bridge-ss-${id}.json"
    ;;
  wg)
    [ -n "$link" ] || return 1
    # Prefer Xray native wireguard outbound (works in multi-outbound routing)
    if ss_wg_ini_to_xray_outbound "$link" "$tag"; then
      ss_activity "protocol.wg_xray" "id=$id tag=$tag"
      return 0
    fi
    ss_start_wg_iface "$id" "$link" wg || return 1
    # Fallback: freedom via interface is not portable — mark unsupported for split
    ss_error "WG iface up but cannot build Xray outbound — use as sole VPN or fix INI"
    return 1
    ;;
  awg)
    # AmneziaWG params not in stock Xray — need awg userspace
    local ini="$link"
    if [ -z "$ini" ] || ! printf '%s' "$ini" | grep -q '\[Interface\]'; then
      ini=$(ss_awg_json_to_ini "$awg_cfg")
    fi
    [ -n "$ini" ] || {
      ss_error "AWG config $id: need connection_url INI or awg_config"
      return 1
    }
    ss_start_wg_iface "$id" "$ini" awg || return 1
    # Bridge: route via local SOCKS is unavailable; expose a tagged freedom+sockopt interface outbound if Xray supports sendThrough
    jq -nc --arg tag "$tag" --arg iface "${WG_IFACE_PREFIX}${id}" '
      {
        tag: $tag,
        protocol: "freedom",
        streamSettings: { sockopt: { interface: $iface } }
      }
    '
    ss_activity "protocol.awg_iface" "id=$id iface=${WG_IFACE_PREFIX}${id}"
    ;;
  *)
    ss_error "Unsupported protocol runtime: $proto"
    return 1
    ;;
  esac
}

ss_apply_protocol_config() {
  # Side-effect start for non-inline runtimes; also validates outbound build
  local config_id="$1"
  local entry outbound
  entry=$(ss_cache_get_config "$config_id") || return 1
  outbound=$(ss_outbound_from_entry "$entry" "$(ss_outbound_tag "$config_id")") || return 1
  # Persist for rebuild merge
  printf '%s\n' "$outbound" >"$ADDON_DATA_DIR/outbound-ss-${config_id}.json"
  return 0
}

ss_protocol_status_matrix() {
  local xray hy2_bin wg_xray awg
  xray=false
  hy2_bin=false
  wg_xray=false
  awg=false
  ss_protocol_supported_on_router vless && xray=true
  { [ -x "$HYSTERIA_BIN" ] || command -v hysteria >/dev/null 2>&1 || [ -x /opt/sbin/hysteria ]; } && hy2_bin=true
  # WG preferred via Xray wireguard outbound
  [ "$xray" = "true" ] && wg_xray=true
  ss_protocol_supported_on_router amnezia-wg-2 && awg=true

  local matrix
  matrix=$(jq -nc \
    --argjson xray "$xray" \
    --argjson hy2_bin "$hy2_bin" \
    --argjson wg_xray "$wg_xray" \
    --argjson awg "$awg" \
    '{
      vless: {runtime:"xray", supported:$xray, status:(if $xray then "ready" else "needs xray" end)},
      "vless-2410": {runtime:"xray", supported:$xray, status:(if $xray then "ready (xray_config/URI, xhttp/grpc)" else "needs xray" end)},
      trojan: {runtime:"xray", supported:$xray, status:(if $xray then "ready" else "needs xray" end)},
      "trojan-2901": {runtime:"xray", supported:$xray, status:(if $xray then "ready" else "needs xray" end)},
      "shadowsocks-2022": {runtime:"xray", supported:$xray, status:(if $xray then "ready" else "needs xray" end)},
      openflux: {runtime:"xray", supported:$xray, status:(if $xray then "ready via API xray_config" else "needs xray" end)},
      hysteria2: {runtime:"hysteria", supported:true, status:(if $hy2_bin then "ready" else "auto-download on apply" end)},
      wg: {runtime:"xray-wireguard", supported:$wg_xray, status:(if $wg_xray then "ready (Xray wireguard outbound from INI)" else "needs xray" end)},
      "amnezia-wg-2": {runtime:"awg", supported:$awg, status:(if $awg then "ready (awg-quick + freedom/interface)" else "needs AmneziaWG awg-quick on router" end)},
      http: {runtime:"xray", supported:$xray, status:(if $xray then "ready" else "needs xray" end)},
      socks5: {runtime:"xray", supported:$xray, status:(if $xray then "ready" else "needs xray" end)}
    }')
  # Persist for UI
  if [ -n "$ADDON_WEB_DIR" ]; then
    mkdir -p "$ADDON_WEB_DIR" 2>/dev/null || true
    printf '%s\n' "$matrix" >"$ADDON_WEB_DIR/protocols.json" 2>/dev/null || true
  fi
  printf '%s\n' "$matrix"
}

ss_stop_all_runtimes() {
  ss_stop_hysteria_all
  ss_stop_wg_all
  rm -f "$ADDON_DATA_DIR"/bridge-ss-*.json "$ADDON_DATA_DIR"/outbound-ss-*.json 2>/dev/null
}
