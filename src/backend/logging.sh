#!/bin/sh
# Activity / error logging with LAN device IP + MAC context

SS_ADDON_LOG="${ADDON_LOGS_DIR}/addon.log"
SS_ACTIVITY_LOG="${ADDON_LOGS_DIR}/activity.log"
SS_ERROR_LOG_FILE="${ADDON_LOGS_DIR}/errors.log"
SS_DEVICES_LOG="${ADDON_LOGS_DIR}/devices.log"
SS_LOG_MAX_BYTES="${SS_LOG_MAX_BYTES:-1048576}" # 1 MiB rotate

ss_log_rotate_one() {
  local f="$1"
  local max="${2:-$SS_LOG_MAX_BYTES}"
  [ -f "$f" ] || return 0
  # Busybox-friendly size check
  local sz
  sz=$(wc -c <"$f" 2>/dev/null | tr -d ' ')
  [ -n "$sz" ] || return 0
  if [ "$sz" -gt "$max" ] 2>/dev/null; then
    mv -f "$f" "${f}.1" 2>/dev/null
    : >"$f"
  fi
}

ss_log_rotate() {
  mkdir -p "$ADDON_LOGS_DIR" 2>/dev/null
  ss_log_rotate_one "$SS_ADDON_LOG"
  ss_log_rotate_one "$SS_ACTIVITY_LOG"
  ss_log_rotate_one "$SS_ERROR_LOG_FILE"
  ss_log_rotate_one "$SS_DEVICES_LOG"
  # Cap Xray logs tightly — USB flash + small RAM routers
  ss_log_rotate_one "$XRAY_ACCESS_LOG" 524288
  ss_log_rotate_one "$XRAY_ERROR_LOG" 524288
}

# Override base helpers with richer logging (sourced after _helper.sh)
ss_log() {
  local msg="$1"
  logger -t "$ADDON_TAG" "$msg"
  mkdir -p "$ADDON_LOGS_DIR" 2>/dev/null
  ss_log_rotate_one "$SS_ADDON_LOG"
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$msg" >>"$SS_ADDON_LOG" 2>/dev/null
  # Mirror to stderr on interactive TTY (ss_console from _helper.sh)
  if type ss_console >/dev/null 2>&1; then
    ss_console "$msg"
  fi
}

ss_ok() { ss_log "OK: $1"; }
ss_info() { ss_log "INFO: $1"; }
ss_warn() {
  ss_log "WARN: $1"
  ss_log_rotate_one "$SS_ERROR_LOG_FILE"
  printf '%s WARN %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >>"$SS_ERROR_LOG_FILE" 2>/dev/null
}
ss_error() {
  ss_log "ERROR: $1"
  ss_log_rotate_one "$SS_ERROR_LOG_FILE"
  printf '%s ERROR %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >>"$SS_ERROR_LOG_FILE" 2>/dev/null
}

ss_mac_to_ip() {
  # Resolve MAC → IPv4 via arp / ip neigh / dhcp leases
  local mac="$1"
  local ip
  mac=$(printf '%s' "$mac" | tr 'A-Z' 'a-z')
  [ -n "$mac" ] || return 1

  if [ -f /var/lib/misc/dnsmasq.leases ]; then
    ip=$(awk -v m="$mac" 'BEGIN{IGNORECASE=1} tolower($2)==m {print $3; exit}' /var/lib/misc/dnsmasq.leases)
    [ -n "$ip" ] && {
      printf '%s' "$ip"
      return 0
    }
  fi

  if command -v ip >/dev/null 2>&1; then
    ip=$(ip -4 neigh show 2>/dev/null | awk -v m="$mac" 'BEGIN{IGNORECASE=1} tolower($5)==m {print $1; exit}')
    [ -n "$ip" ] && {
      printf '%s' "$ip"
      return 0
    }
  fi

  if [ -f /proc/net/arp ]; then
    ip=$(awk -v m="$mac" 'BEGIN{IGNORECASE=1} NR>1 {
      gsub(/:/,"",$4); gm=m; gsub(/:/,"",gm);
      if (tolower($4)==tolower(gm) || tolower($4)==m) { print $1; exit }
    }' /proc/net/arp 2>/dev/null)
    # Also try colon form
    [ -z "$ip" ] && ip=$(awk -v m="$mac" 'BEGIN{IGNORECASE=1} NR>1 && tolower($4)==m {print $1; exit}' /proc/net/arp)
    [ -n "$ip" ] && {
      printf '%s' "$ip"
      return 0
    }
  fi
  return 1
}

ss_mac_to_name() {
  local mac="$1" raw name
  mac=$(printf '%s' "$mac" | tr 'a-z' 'A-Z')
  raw=$(nvram get custom_clientlist 2>/dev/null || true)
  if [ -n "$raw" ]; then
    name=$(printf '%s' "$raw" | tr '<' '\n' | awk -F'>' -v m="$mac" 'toupper($2)==m {print $1; exit}')
    [ -n "$name" ] && {
      printf '%s' "$name"
      return 0
    }
  fi
  if [ -f /var/lib/misc/dnsmasq.leases ]; then
    name=$(awk -v m="$(printf '%s' "$mac" | tr 'A-Z' 'a-z')" 'BEGIN{IGNORECASE=1} tolower($2)==m {print $4; exit}' /var/lib/misc/dnsmasq.leases)
    [ -n "$name" ] && [ "$name" != "*" ] && {
      printf '%s' "$name"
      return 0
    }
  fi
  return 1
}

ss_device_ctx() {
  # Print "ip=x.x.x.x mac=AA:.. name=Foo" for a MAC (best-effort)
  local mac="$1"
  local ip name
  mac=$(printf '%s' "$mac" | tr 'a-z' 'A-Z')
  ip=$(ss_mac_to_ip "$mac" 2>/dev/null || true)
  name=$(ss_mac_to_name "$mac" 2>/dev/null || true)
  printf 'mac=%s' "$mac"
  [ -n "$ip" ] && printf ' ip=%s' "$ip"
  [ -n "$name" ] && printf ' name=%s' "$name"
}

ss_activity() {
  # ss_activity <action> <message> [mac]
  local action="$1"
  local message="$2"
  local mac="$3"
  local line ctx
  mkdir -p "$ADDON_LOGS_DIR" 2>/dev/null
  ss_log_rotate_one "$SS_ACTIVITY_LOG"
  line="$(date '+%Y-%m-%d %H:%M:%S') action=${action} ${message}"
  if [ -n "$mac" ]; then
    ctx=$(ss_device_ctx "$mac")
    line="${line} ${ctx}"
  fi
  printf '%s\n' "$line" >>"$SS_ACTIVITY_LOG" 2>/dev/null
  # Mirror important actions into main addon log
  ss_log "ACTIVITY [${action}] ${message}${mac:+ mac=$mac}"
}

ss_log_devices_snapshot() {
  # Write current LAN clients (IP + MAC + name) into devices.log and activity
  local stamp clients count line mac
  ss_ensure_dirs
  stamp=$(date '+%Y-%m-%d %H:%M:%S')
  ss_log_rotate_one "$SS_DEVICES_LOG"
  if type ss_clientlist_json >/dev/null 2>&1; then
    clients=$(ss_clientlist_json 2>/dev/null || echo '[]')
  else
    clients='[]'
  fi
  {
    echo "===== devices snapshot @ $stamp ====="
    printf '%s' "$clients" | jq -r '
      .[] |
      "ip=\(.ip // "-")\tmac=\(.mac // "-")\tname=\(.name // "-")\tonline=\(.online // false)\tsource=\(.source // "-")"
    ' 2>/dev/null
    count=$(printf '%s' "$clients" | jq 'length' 2>/dev/null || echo 0)
    echo "===== total=$count ====="
  } >>"$SS_DEVICES_LOG" 2>/dev/null
  count=$(printf '%s' "$clients" | jq 'length' 2>/dev/null || echo 0)
  ss_activity "devices.snapshot" "LAN clients logged count=${count:-0}"
  # Also mirror each device into activity.log with explicit IP
  printf '%s' "$clients" | jq -c '.[]' 2>/dev/null | while read -r line; do
    [ -n "$line" ] || continue
    mac=$(printf '%s' "$line" | jq -r '.mac // empty')
    ss_activity "devices.entry" "$(printf '%s' "$line" | jq -r '"ip=\(.ip // "-") name=\(.name // "-") online=\(.online // false)"')" "$mac"
  done
}

ss_log_policy_rules() {
  # Log each policy rule with resolved device IP
  local rule mac mode ports proto ip name
  [ -f "$SS_POLICIES_FILE" ] || return 0
  ss_activity "policies.apply" "catchall=$(jq -r '.catchall // false' "$SS_POLICIES_FILE") rules=$(jq '.rules|length' "$SS_POLICIES_FILE")"
  jq -c '.rules // [] | .[]' "$SS_POLICIES_FILE" 2>/dev/null | while read -r rule; do
    mac=$(printf '%s' "$rule" | jq -r '.mac // empty')
    mode=$(printf '%s' "$rule" | jq -r '.mode // empty')
    ports=$(printf '%s' "$rule" | jq -r '.ports // "-"')
    proto=$(printf '%s' "$rule" | jq -r '.proto // "tcp"')
    name=$(printf '%s' "$rule" | jq -r '.name // empty')
    ip=$(ss_mac_to_ip "$mac" 2>/dev/null || echo "-")
    [ -z "$name" ] && name=$(ss_mac_to_name "$mac" 2>/dev/null || echo "-")
    ss_activity "policies.rule" "mode=${mode} ports=${ports} proto=${proto} name=${name} ip=${ip}" "$mac"
  done
}

ss_tail_logs() {
  local kind="${1:-addon}"
  local lines="${2:-100}"
  case "$kind" in
  access) tail -n "$lines" "$XRAY_ACCESS_LOG" 2>/dev/null || echo "(no access log)" ;;
  error | errors) tail -n "$lines" "$SS_ERROR_LOG_FILE" 2>/dev/null || echo "(no error log)" ;;
  xray-error) tail -n "$lines" "$XRAY_ERROR_LOG" 2>/dev/null || echo "(no xray error log)" ;;
  activity) tail -n "$lines" "$SS_ACTIVITY_LOG" 2>/dev/null || echo "(no activity log)" ;;
  devices) tail -n "$lines" "$SS_DEVICES_LOG" 2>/dev/null || echo "(no devices log)" ;;
  *) tail -n "$lines" "$SS_ADDON_LOG" 2>/dev/null || echo "(no addon log)" ;;
  esac
}

ss_logs_clear() {
  local kind="${1:-all}"
  mkdir -p "$ADDON_LOGS_DIR"
  case "$kind" in
  addon) : >"$SS_ADDON_LOG" ;;
  activity) : >"$SS_ACTIVITY_LOG" ;;
  errors) : >"$SS_ERROR_LOG_FILE" ;;
  devices) : >"$SS_DEVICES_LOG" ;;
  all)
    : >"$SS_ADDON_LOG"
    : >"$SS_ACTIVITY_LOG"
    : >"$SS_ERROR_LOG_FILE"
    : >"$SS_DEVICES_LOG"
    ;;
  *)
    ss_error "Unknown log kind: $kind"
    return 1
    ;;
  esac
  ss_activity "logs.clear" "cleared kind=$kind"
}
