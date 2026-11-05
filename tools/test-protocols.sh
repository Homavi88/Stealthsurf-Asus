#!/bin/sh
# Offline unit checks for protocol outbound builders (no router / no API).
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export ADDON_TAG="stealthsurf"
export ADDON_VERSION=1.0.4
export ADDON_TMP_DIR="$TMP/tmp"
export ADDON_DATA_DIR="$TMP/data"
export ADDON_WEB_DIR="$TMP/web"
export ADDON_SHARE_DIR="$TMP"
export ADDON_LOGS_DIR="$TMP/logs"
export HYSTERIA_BIN="/nonexistent"
export XRAY_BIN="/nonexistent"
export AWG_BIN="/nonexistent"
export XRAY_ACCESS_LOG="$TMP/access.log"
export XRAY_ERROR_LOG="$TMP/error.log"
export SS_SOCKS_PORT=10808
export SS_HTTP_PORT=10809
export SS_TPROXY_PORT=10810
export SS_REDIRECT_PORT=10811
export SS_DNS_PORT=5353
export SS_DNS_MODE=OFF
export SS_MODE=proxy
export SS_ROUTING_FILE="$TMP/routing.json"
export SS_OUTBOUNDS_FILE="$TMP/outbounds.json"
export SS_ENDPOINTS_FILE="$TMP/endpoints.json"
export SS_CONF_FILE="$TMP/stealthsurf.conf"
export SS_ENABLED_OUTBOUNDS=""
export SS_DEFAULT_OUTBOUND="direct"
export SS_ACTIVE_CONFIG_ID=""
mkdir -p "$ADDON_TMP_DIR" "$ADDON_DATA_DIR" "$ADDON_WEB_DIR" "$ADDON_LOGS_DIR"
echo '{"rules":[],"domainStrategy":"AsIs"}' >"$SS_ROUTING_FILE"
echo '{"enabled":[],"default":"direct"}' >"$SS_OUTBOUNDS_FILE"
echo '[]' >"$SS_ENDPOINTS_FILE"
: >"$SS_CONF_FILE"

# shellcheck disable=SC1091
. "$ROOT/src/backend/_helper.sh"
ss_log() { :; }
ss_save_conf() { :; }
ss_info() { :; }
ss_ok() { :; }
ss_warn() { :; }
ss_error() { echo "ERR: $*" >&2; }
ss_activity() { :; }
ss_fw_detect_mode() { echo proxy; }
ss_cache_get_config() { return 1; }
# shellcheck disable=SC1091
. "$ROOT/src/backend/link_parse.sh"
# shellcheck disable=SC1091
. "$ROOT/src/backend/routing.sh"
# shellcheck disable=SC1091
. "$ROOT/src/backend/protocols.sh"
# After modules: force xray present for matrix soft checks
ss_protocol_supported_on_router() {
  case "$(ss_protocol_runtime "$1")" in
  xray | wg | hysteria) return 0 ;;
  awg) return 1 ;;
  *) return 1 ;;
  esac
}

fail=0
assert_jq() {
  local name="$1" json="$2" expr="$3"
  if printf '%s' "$json" | jq -e "$expr" >/dev/null 2>&1; then
    echo "OK  $name"
  else
    echo "FAIL $name"
    echo "  json=$json"
    fail=$((fail + 1))
  fi
}

ob=$(ss_parse_vless 'vless://11111111-1111-1111-1111-111111111111@node.example:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.cloudflare.com&fp=chrome&pbk=PUB&sid=abcd&type=tcp#test')
assert_jq "vless reality" "$ob" '.protocol=="vless" and .settings.vnext[0].address=="node.example" and .streamSettings.security=="reality"'

ob=$(ss_parse_vless 'vless://22222222-2222-2222-2222-222222222222@x.example:443?type=xhttp&path=/x&mode=auto&security=tls&sni=x.example&fp=chrome#xh')
assert_jq "vless xhttp" "$ob" '.streamSettings.network=="xhttp" and .streamSettings.xhttpSettings.path=="/x"'

ob=$(ss_parse_trojan 'trojan://secret@t.example:443?sni=t.example&security=tls#tr')
assert_jq "trojan" "$ob" '.protocol=="trojan" and .settings.servers[0].password=="secret"'

ob=$(ss_parse_shadowsocks 'ss://2022-blake3-aes-128-gcm:pass@ss.example:8388#ss')
assert_jq "ss2022" "$ob" '.protocol=="shadowsocks" and .settings.servers[0].method=="2022-blake3-aes-128-gcm"'

entry=$(jq -nc '{
  id: 42,
  protocol: "openflux",
  connection_url: "vless://should-not-use@bad:1",
  xray_config: {
    outbounds: [
      {tag:"direct", protocol:"freedom"},
      {tag:"proxy", protocol:"vless", settings:{vnext:[{address:"good.example",port:443,users:[{id:"u",encryption:"none"}]}]},
       streamSettings:{network:"tcp",security:"reality",realitySettings:{serverName:"s",publicKey:"p",shortId:"s",fingerprint:"chrome"}}}
    ]
  }
}')
ob=$(ss_outbound_from_entry "$entry" "ss-42")
assert_jq "openflux via xray_config" "$ob" '.tag=="ss-42" and .protocol=="vless" and .settings.vnext[0].address=="good.example"'

wg_ini='[Interface]
PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEE=
Address = 10.8.0.2/32
DNS = 1.1.1.1
MTU = 1280

[Peer]
PublicKey = BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=
Endpoint = wg.example:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25'
ob=$(ss_wg_ini_to_xray_outbound "$wg_ini" "ss-7")
assert_jq "wg xray outbound" "$ob" '.protocol=="wireguard" and .settings.peers[0].endpoint=="wg.example:51820" and .tag=="ss-7"'

entry_wg=$(jq -nc --arg ini "$wg_ini" '{id:7, protocol:"wg", connection_url:$ini}')
ob=$(ss_outbound_from_entry "$entry_wg" "ss-7")
assert_jq "wg via entry" "$ob" '.protocol=="wireguard" and .tag=="ss-7"'

host=$(ss_extract_host_from_xray_config '{"outbounds":[{"protocol":"vless","settings":{"vnext":[{"address":"ep.example","port":443}]}}]}')
[ "$host" = "ep.example" ] && echo "OK  extract host xray_config" || {
  echo "FAIL extract host ($host)"
  fail=$((fail + 1))
}

[ "$(ss_protocol_runtime openflux)" = "xray" ] && echo "OK  openflux→xray" || {
  echo "FAIL openflux runtime"
  fail=$((fail + 1))
}
[ "$(ss_protocol_runtime amnezia-wg-2)" = "awg" ] && echo "OK  awg runtime" || {
  echo "FAIL awg runtime"
  fail=$((fail + 1))
}

matrix=$(ss_protocol_status_matrix)
assert_jq "matrix openflux" "$matrix" '.openflux.runtime=="xray"'
assert_jq "matrix hysteria soft" "$matrix" '.hysteria2.supported==true'
assert_jq "matrix file written" "$(cat "$ADDON_WEB_DIR/protocols.json")" '.wg.runtime=="xray-wireguard"'

if [ "$fail" -ne 0 ]; then
  echo "FAILED: $fail"
  exit 1
fi
echo "All protocol tests passed"
