#!/bin/sh

# Merlin custom_settings / httpd service hooks call:
#   stealthsurf service_event <action> [arg]
# Payload JSON may be posted by the ASP page into /tmp/stealthsurf_payload.json

ss_read_payload() {
  local f="/tmp/stealthsurf_payload.json"
  local amng custom
  if [ -f "$f" ]; then
    cat "$f"
    return 0
  fi
  # Fallback: amng_custom may carry a JSON blob from the WebUI form
  custom=$(nvram get amng_custom 2>/dev/null)
  if [ -n "$custom" ] && printf '%s' "$custom" | jq -e . >/dev/null 2>&1; then
    printf '%s' "$custom"
    return 0
  fi
  echo '{}'
}

ss_service_event() {
  local action="$1"
  local arg="$2"
  local payload
  payload=$(ss_read_payload)

  case "$action" in
  init)
    ss_write_state
    ss_json_response true "ok" "$(jq -nc \
      --slurpfile state "$SS_STATE_FILE" \
      --arg has_key "$( [ -n "$SS_API_KEY" ] && echo true || echo false )" \
      '{state: ($state[0] // {}), has_api_key: ($has_key == "true")}')"
    ;;
  setkey)
    SS_API_KEY=$(printf '%s' "$payload" | jq -r '.api_key // empty')
    if [ -z "$SS_API_KEY" ]; then
      ss_json_response false "api_key missing" null
      return 1
    fi
    ss_save_conf
    if ss_api_verify_key >/dev/null; then
      ss_json_response true "API key saved" "$(cat "$SS_CACHE_PROFILE")"
    else
      ss_json_response false "API key rejected" null
      return 1
    fi
    ;;
  sync)
    ss_api_sync_configs >/dev/null || {
      ss_json_response false "sync configs failed" null
      return 1
    }
    ss_api_sync_locations >/dev/null || true
    ss_json_response true "synced" "$(jq -nc \
      --slurpfile configs "$SS_CACHE_CONFIGS" \
      --slurpfile locations "$SS_CACHE_LOCATIONS" \
      '{configs: ($configs[0] // []), locations: ($locations[0] // [])}')"
    ;;
  apply)
    local id
    id=$(printf '%s' "$payload" | jq -r '.config_id // empty')
    [ -n "$id" ] || id="$arg"
    if ss_apply_config_id "$id"; then
      ss_json_response true "applied $id" "$(cat "$SS_STATE_FILE")"
    else
      ss_json_response false "apply failed" null
      return 1
    fi
    ;;
  updatesettings)
    local id body
    id=$(printf '%s' "$payload" | jq -r '.config_id // empty')
    body=$(printf '%s' "$payload" | jq -c '.settings // empty')
    if [ -z "$id" ] || [ -z "$body" ] || [ "$body" = "null" ]; then
      ss_json_response false "config_id and settings required" null
      return 1
    fi
    if ss_api_update_settings "$id" "$body" >/dev/null; then
      ss_json_response true "settings updated" "$(cat "$SS_CACHE_CONFIGS")"
    else
      ss_json_response false "settings update failed" null
      return 1
    fi
    ;;
  start)
    ss_start && ss_json_response true "started" "$(cat "$SS_STATE_FILE")" || ss_json_response false "start failed" null
    ;;
  stop)
    ss_stop && ss_json_response true "stopped" "$(cat "$SS_STATE_FILE")" || ss_json_response false "stop failed" null
    ;;
  restart)
    ss_restart && ss_json_response true "restarted" "$(cat "$SS_STATE_FILE")" || ss_json_response false "restart failed" null
    ;;
  status)
    ss_status >/dev/null
    ss_json_response true "status" "$(cat "$SS_STATE_FILE")"
    ;;
  *)
    ss_json_response false "unknown action: $action" null
    return 1
    ;;
  esac
}
