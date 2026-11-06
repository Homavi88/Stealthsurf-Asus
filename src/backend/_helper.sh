#!/bin/sh

ss_log() {
  logger -t "$ADDON_TAG" "$1"
  mkdir -p "$ADDON_LOGS_DIR" 2>/dev/null
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >>"$ADDON_LOGS_DIR/addon.log" 2>/dev/null
}

ss_ok() { ss_log "OK: $1"; }
ss_info() { ss_log "INFO: $1"; }
ss_warn() { ss_log "WARN: $1"; }
ss_error() { ss_log "ERROR: $1"; }

ss_ensure_dirs() {
  mkdir -p "$ADDON_SHARE_DIR" "$ADDON_LOGS_DIR" "$ADDON_TMP_DIR" "/opt/etc/xray" \
    "$ADDON_DATA_DIR" "$ADDON_BACKUP_DIR" 2>/dev/null
  mkdir -p "$(dirname "$SS_CONF_FILE")" 2>/dev/null
  # Default JSON stores
  [ -f "$SS_POLICIES_FILE" ] || echo '{"rules":[]}' >"$SS_POLICIES_FILE"
  [ -f "$SS_ROUTING_FILE" ] || echo '{"domainStrategy":"AsIs","default_outbound":"","rules":[],"preset":""}' >"$SS_ROUTING_FILE"
  [ -f "$SS_OUTBOUNDS_FILE" ] || echo '{"enabled":[],"default":""}' >"$SS_OUTBOUNDS_FILE"
  [ -f "$SS_CACHE_KEYS" ] || echo '[]' >"$SS_CACHE_KEYS"
  [ -f "$SS_CACHE_SUBSCRIPTIONS" ] || echo '[]' >"$SS_CACHE_SUBSCRIPTIONS"
  [ -f "$SS_CACHE_CONFIGS" ] || echo '[]' >"$SS_CACHE_CONFIGS"
  [ -f "$SS_ENDPOINTS_FILE" ] || echo '[]' >"$SS_ENDPOINTS_FILE"
}

ss_save_conf() {
  ss_ensure_dirs
  # Sync enabled outbounds / default from outbounds file if present
  if [ -f "$SS_OUTBOUNDS_FILE" ]; then
    SS_ENABLED_OUTBOUNDS=$(jq -r '(.enabled // []) | map(tostring) | join(" ")' "$SS_OUTBOUNDS_FILE" 2>/dev/null)
    SS_DEFAULT_OUTBOUND=$(jq -r '.default // empty' "$SS_OUTBOUNDS_FILE" 2>/dev/null)
  fi
  cat >"$SS_CONF_FILE" <<EOF
SS_API_KEY='$SS_API_KEY'
SS_API_KEYS='$SS_API_KEYS'
SS_API_BASE='$SS_API_BASE'
SS_ACTIVE_CONFIG_ID='$SS_ACTIVE_CONFIG_ID'
SS_DEFAULT_OUTBOUND='$SS_DEFAULT_OUTBOUND'
SS_ENABLED_OUTBOUNDS='$SS_ENABLED_OUTBOUNDS'
SS_SOCKS_PORT='$SS_SOCKS_PORT'
SS_HTTP_PORT='$SS_HTTP_PORT'
SS_TPROXY_PORT='$SS_TPROXY_PORT'
SS_REDIRECT_PORT='$SS_REDIRECT_PORT'
SS_DNS_PORT='$SS_DNS_PORT'
SS_MODE='$SS_MODE'
SS_DNS_MODE='$SS_DNS_MODE'
SS_PROXY_MODE='$SS_PROXY_MODE'
SS_AUTO_START='$SS_AUTO_START'
SS_WATCHDOG='$SS_WATCHDOG'
SS_FALLBACK_OUTBOUND='$SS_FALLBACK_OUTBOUND'
SS_AUTO_BACKUP='${SS_AUTO_BACKUP:-1}'
SS_BACKUP_KEEP='${SS_BACKUP_KEEP:-10}'
SS_LOG_MAX_BYTES='${SS_LOG_MAX_BYTES:-1048576}'
SS_STARTUP_DELAY='${SS_STARTUP_DELAY:-8}'
EOF
  chmod 600 "$SS_CONF_FILE"
}

ss_with_lock() {
  # ss_with_lock <lockname> <command...>
  local lockname="$1"
  shift
  local lockfile="/tmp/${ADDON_TAG}.${lockname}.lock"
  if command -v flock >/dev/null 2>&1; then
    (
      flock -w 30 9 || {
        ss_error "Could not acquire lock $lockname"
        exit 1
      }
      "$@"
    ) 9>"$lockfile"
  else
    local stamp="$lockfile.dir"
    local tries=0
    while ! mkdir "$stamp" 2>/dev/null; do
      tries=$((tries + 1))
      [ "$tries" -gt 30 ] && {
        ss_error "Could not acquire lock $lockname"
        return 1
      }
      sleep 1
    done
    echo "$$" >"$stamp/pid"
    "$@"
    local rc=$?
    rm -rf "$stamp"
    return $rc
  fi
}

ss_json_response() {
  local status="$1"
  local message="$2"
  local data="${3:-null}"
  local status_json="false"
  case "$status" in
  true | 1 | ok | OK) status_json="true" ;;
  esac
  ss_ensure_dirs
  mkdir -p "$ADDON_WEB_DIR" 2>/dev/null
  jq -nc \
    --argjson status "$status_json" \
    --arg message "$message" \
    --argjson data "$data" \
    --argjson ts "$(date +%s)" \
    '{status:$status, message:$message, data:$data, ts:$ts}' >"$SS_UI_RESPONSE"
}

ss_require_key() {
  if [ -z "$SS_API_KEY" ] && [ -z "$SS_API_KEYS" ]; then
    ss_error "API key is not set. Use: stealthsurf set-key <stlth_...>"
    return 1
  fi
  if [ -z "$SS_API_KEY" ] && [ -n "$SS_API_KEYS" ]; then
    SS_API_KEY=$(printf '%s' "$SS_API_KEYS" | awk '{print $1}')
  fi
  case "$SS_API_KEY" in
  stlth_????????_????????????????????????) ;;
  *)
    ss_warn "API key format looks unusual (expected stlth_<8hex>_<24hex>)"
    ;;
  esac
  return 0
}

ss_all_api_keys() {
  # Print unique API keys (primary + extras), one per line
  local k
  {
    [ -n "$SS_API_KEY" ] && printf '%s\n' "$SS_API_KEY"
    for k in $SS_API_KEYS; do
      [ -n "$k" ] && printf '%s\n' "$k"
    done
    if [ -f "$SS_CACHE_KEYS" ]; then
      jq -r '.[] | .key // empty' "$SS_CACHE_KEYS" 2>/dev/null
    fi
  } | awk 'NF && !seen[$0]++'
}

ss_urldecode() {
  printf '%b' "$(printf '%s' "$1" | sed 's/+/ /g; s/%/\\x/g')"
}

ss_get_query_param() {
  # ss_get_query_param "host=a&port=443&security=reality" security
  local qs="$1"
  local key="$2"
  local pair
  local IFS='&'
  for pair in $qs; do
    case "$pair" in
    "$key"=*)
      ss_urldecode "${pair#*=}"
      return 0
      ;;
    esac
  done
  return 1
}

ss_detect_arch() {
  local machine
  machine=$(uname -m 2>/dev/null || echo unknown)
  case "$machine" in
  aarch64 | arm64) echo "arm64-v8a" ;;
  armv7* | armv6* | arm) echo "arm32-v7a" ;;
  x86_64 | amd64) echo "64" ;;
  i386 | i686) echo "32" ;;
  mips64*) echo "mips64" ;;
  mips*) echo "mips32" ;;
  *) echo "arm64-v8a" ;; # Merlin ARM64 default
  esac
}

ss_lan_cidrs() {
  # Best-effort LAN CIDRs for anti-loop
  local lan_ip mask cidr
  lan_ip=$(nvram get lan_ipaddr 2>/dev/null || echo "192.168.1.1")
  mask=$(nvram get lan_netmask 2>/dev/null || echo "255.255.255.0")
  case "$mask" in
  255.255.255.0) cidr="${lan_ip%.*}.0/24" ;;
  255.255.0.0) cidr="${lan_ip%.*.*}.0.0/16" ;;
  255.255.255.128) cidr="$lan_ip/25" ;;
  *) cidr="${lan_ip%.*}.0/24" ;;
  esac
  printf '%s\n' "$cidr" "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16" "127.0.0.0/8" "169.254.0.0/16"
}

ss_router_ip() {
  nvram get lan_ipaddr 2>/dev/null || ip -4 addr show br0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1
}

ss_resolve_system_iptables() {
  # Prefer firmware/busybox iptables over Entware — Entware in PATH breaks Merlin NAT.
  local bin
  for bin in /usr/sbin/iptables /sbin/iptables /bin/iptables; do
    if [ -x "$bin" ]; then
      printf '%s\n' "$bin"
      return 0
    fi
  done
  # Last resort: whatever is on PATH (may be Entware)
  if command -v iptables >/dev/null 2>&1; then
    command -v iptables
    return 0
  fi
  return 1
}

ss_resolve_system_ip6tables() {
  local bin
  for bin in /usr/sbin/ip6tables /sbin/ip6tables /bin/ip6tables; do
    if [ -x "$bin" ]; then
      printf '%s\n' "$bin"
      return 0
    fi
  done
  command -v ip6tables 2>/dev/null || return 1
}

ss_iptables_init() {
  # Cache absolute paths once per process
  if [ -z "$SS_IPTABLES" ]; then
    SS_IPTABLES=$(ss_resolve_system_iptables) || SS_IPTABLES="iptables"
  fi
  if [ -z "$SS_IP6TABLES" ]; then
    SS_IP6TABLES=$(ss_resolve_system_ip6tables 2>/dev/null) || SS_IP6TABLES="ip6tables"
  fi
}

ss_dokodemo_listening() {
  # True if transparent inbound port is accepting connections (avoid blackhole LAN)
  local mode port
  mode=$(ss_fw_detect_mode 2>/dev/null || echo proxy)
  case "$mode" in
  tproxy) port="${SS_TPROXY_PORT:-10810}" ;;
  redirect) port="${SS_REDIRECT_PORT:-10811}" ;;
  *) return 0 ;; # proxy mode needs no hijack port
  esac
  if command -v netstat >/dev/null 2>&1; then
    netstat -lntu 2>/dev/null | grep -qE "[:.]${port}[[:space:]]" && return 0
  fi
  if [ -r /proc/net/tcp ]; then
    # hex port
    local hex
    hex=$(printf '%04X' "$port")
    grep -qiE ":${hex}[[:space:]]" /proc/net/tcp /proc/net/tcp6 2>/dev/null && return 0
  fi
  # Fallback: assume OK if our xray pid is alive (port check unavailable)
  ss_xray_running 2>/dev/null
}

ss_protocol_runtime() {
  # Map StealthSurf protocol → runtime: xray|hysteria|wg|awg|unsupported
  # openflux and wg prefer Xray (xray_config / wireguard outbound); awg needs awg-quick.
  local proto="$1"
  case "$proto" in
  vless | vless-2410 | trojan | trojan-2901 | shadowsocks-2022 | shadowsocks | ss | openflux)
    echo xray
    ;;
  hysteria2 | hy2)
    echo hysteria
    ;;
  wg | wireguard)
    echo wg
    ;;
  amnezia-wg-2 | amneziawg | awg)
    echo awg
    ;;
  http | socks5 | socks)
    echo xray
    ;;
  *)
    echo unsupported
    ;;
  esac
}

ss_protocol_supported_on_router() {
  local proto="$1"
  local runtime
  runtime=$(ss_protocol_runtime "$proto")
  case "$runtime" in
  xray)
    # openflux / vless* / trojan* / ss / http / socks → need Xray
    [ -x "$XRAY_BIN" ] || command -v xray >/dev/null 2>&1
    ;;
  hysteria)
    [ -x "$HYSTERIA_BIN" ] || command -v hysteria >/dev/null 2>&1 || [ -x /opt/sbin/hysteria ]
    ;;
  wg)
    # Preferred path is Xray wireguard outbound; iface fallback needs wg/wg-quick
    if [ -x "$XRAY_BIN" ] || command -v xray >/dev/null 2>&1; then
      return 0
    fi
    command -v wg >/dev/null 2>&1 || [ -x /usr/sbin/wg ]
    ;;
  awg)
    command -v awg-quick >/dev/null 2>&1 || command -v awg >/dev/null 2>&1 || [ -x "$AWG_BIN" ]
    ;;
  *)
    return 1
    ;;
  esac
}

ss_jq_file_or() {
  local file="$1"
  local fallback="$2"
  if [ -f "$file" ] && jq -e . "$file" >/dev/null 2>&1; then
    cat "$file"
  else
    printf '%s' "$fallback"
  fi
}

# ── XrayUI coexistence ────────────────────────────────────────────────
# Both addons drive transparent proxy. Separate marks/tables avoid collision,
# but dual hijack of LAN still breaks internet. Refuse start while XrayUI runs.

SS_XRAYUI_PIDFILE="${SS_XRAYUI_PIDFILE:-/var/run/xray.pid}"
SS_XRAYUI_DESIRED="${SS_XRAYUI_DESIRED:-/tmp/xrayui.desired}"
SS_XRAYUI_CONFIG="${SS_XRAYUI_CONFIG:-/opt/etc/xray/config.json}"
SS_XRAYUI_MSG_RU="XrayUI сейчас работает. Остановите XrayUI (VPN → XrayUI → Stop), затем запускайте StealthSurf. Одновременно оба аддона нельзя."

ss_xrayui_installed() {
  [ -x /jffs/scripts/xrayui ] && return 0
  [ -d /opt/share/xrayui ] && return 0
  [ -d /jffs/addons/xrayui ] && return 0
  [ -f /opt/etc/xrayui.conf ] && return 0
  return 1
}

ss_xrayui_pid_alive() {
  local pid=""
  [ -f "$SS_XRAYUI_PIDFILE" ] || return 1
  pid=$(cat "$SS_XRAYUI_PIDFILE" 2>/dev/null)
  [ -n "$pid" ] || return 1
  # Must not be our StealthSurf Xray
  if [ -f "$XRAY_PIDFILE" ]; then
    local ours
    ours=$(cat "$XRAY_PIDFILE" 2>/dev/null)
    [ -n "$ours" ] && [ "$pid" = "$ours" ] && return 1
  fi
  kill -0 "$pid" 2>/dev/null
}

ss_xrayui_process_running() {
  # xrayui uses /opt/etc/xray/config.json; we use stealthsurf.json
  local cfg="$SS_XRAYUI_CONFIG"
  local line=""
  # BusyBox ps: look for foreign xray config in cmdline
  if command -v ps >/dev/null 2>&1; then
    # shellcheck disable=SC2009
    line=$(ps w 2>/dev/null | grep -E '[x]ray.*(run )?.*(/opt/etc/xray/config\.json|xrayui)' | grep -v stealthsurf | head -1)
    [ -n "$line" ] && return 0
  fi
  # /proc fallback
  local p cmd
  for p in /proc/[0-9]*; do
    [ -r "$p/cmdline" ] || continue
    cmd=$(tr '\0' ' ' <"$p/cmdline" 2>/dev/null)
    case "$cmd" in
    *xray*"$cfg"* | *xray*xrayui*)
      case "$cmd" in
      *stealthsurf.json*) continue ;;
      *) return 0 ;;
      esac
      ;;
    esac
  done
  return 1
}

ss_xrayui_firewall_active() {
  local ipt
  ipt=$(ss_resolve_system_iptables 2>/dev/null) || ipt="iptables"
  "$ipt" -w -t nat -nL XRAYUI >/dev/null 2>&1 && return 0
  "$ipt" -w -t mangle -nL XRAYUI >/dev/null 2>&1 && return 0
  return 1
}

ss_xrayui_running() {
  # Strong signals that XrayUI dataplane is up
  if ss_xrayui_pid_alive; then
    return 0
  fi
  if ss_xrayui_process_running; then
    return 0
  fi
  # Desired + live firewall chain = working transparent session
  if [ -f "$SS_XRAYUI_DESIRED" ] && ss_xrayui_firewall_active; then
    return 0
  fi
  return 1
}

ss_xrayui_conflict_message() {
  printf '%s\n' "$SS_XRAYUI_MSG_RU"
}

ss_xrayui_status_json() {
  local installed=false running=false conflict=""
  ss_xrayui_installed && installed=true
  if ss_xrayui_running; then
    running=true
    conflict="xrayui"
  fi
  jq -nc \
    --argjson installed "$installed" \
    --argjson running "$running" \
    --arg conflict "$conflict" \
    --arg message "$( [ "$running" = true ] && ss_xrayui_conflict_message || echo '' )" \
    '{
      installed:$installed,
      running:$running,
      conflict:(if $conflict=="" then null else $conflict end),
      message:(if $message=="" then null else $message end)
    }'
}

ss_refuse_if_xrayui() {
  # Call before start / autostart / watchdog restart
  if ss_xrayui_running; then
    ss_error "$(ss_xrayui_conflict_message)"
    if type ss_desired_clear >/dev/null 2>&1; then
      ss_desired_clear 2>/dev/null || true
    fi
    ss_activity "start.blocked" "xrayui_running=1"
    return 1
  fi
  return 0
}
