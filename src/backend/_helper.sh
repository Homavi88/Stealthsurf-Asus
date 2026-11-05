#!/bin/sh

ss_log() {
  logger -t "$ADDON_TAG" "$1"
}

ss_ok() { ss_log "OK: $1"; }
ss_info() { ss_log "INFO: $1"; }
ss_warn() { ss_log "WARN: $1"; }
ss_error() { ss_log "ERROR: $1"; }

ss_ensure_dirs() {
  mkdir -p "$ADDON_SHARE_DIR" "$ADDON_LOGS_DIR" "$ADDON_TMP_DIR" "/opt/etc/xray" 2>/dev/null
  mkdir -p "$(dirname "$SS_CONF_FILE")" 2>/dev/null
}

ss_save_conf() {
  ss_ensure_dirs
  cat >"$SS_CONF_FILE" <<EOF
SS_API_KEY='$SS_API_KEY'
SS_API_BASE='$SS_API_BASE'
SS_ACTIVE_CONFIG_ID='$SS_ACTIVE_CONFIG_ID'
SS_SOCKS_PORT='$SS_SOCKS_PORT'
SS_HTTP_PORT='$SS_HTTP_PORT'
SS_MODE='$SS_MODE'
EOF
  chmod 600 "$SS_CONF_FILE"
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
  if [ -z "$SS_API_KEY" ]; then
    ss_error "API key is not set. Use: stealthsurf set-key <stlth_...>"
    return 1
  fi
  case "$SS_API_KEY" in
  stlth_????????_????????????????????????) ;;
  *)
    ss_warn "API key format looks unusual (expected stlth_<8hex>_<24hex>)"
    ;;
  esac
  return 0
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
