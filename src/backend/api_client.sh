#!/bin/sh

ss_api() {
  # ss_api METHOD PATH [JSON_BODY]
  local method="$1"
  local path="$2"
  local body="$3"
  local tmp_headers tmp_body http_code
  local url

  ss_require_key || return 1
  ss_ensure_dirs

  url="${SS_API_BASE}${path}"
  tmp_headers="$ADDON_TMP_DIR/api.headers.$$"
  tmp_body="$ADDON_TMP_DIR/api.body.$$"

  if [ -n "$body" ]; then
    http_code=$(curl -sS -o "$tmp_body" -D "$tmp_headers" -w '%{http_code}' \
      -X "$method" "$url" \
      -H "Authorization: Bearer $SS_API_KEY" \
      -H "Content-Type: application/json" \
      -H "Accept: application/json" \
      -H "User-Agent: stealthsurf-merlin/$ADDON_VERSION" \
      --connect-timeout 15 --max-time 45 \
      -d "$body" 2>/dev/null) || http_code="000"
  else
    http_code=$(curl -sS -o "$tmp_body" -D "$tmp_headers" -w '%{http_code}' \
      -X "$method" "$url" \
      -H "Authorization: Bearer $SS_API_KEY" \
      -H "Accept: application/json" \
      -H "User-Agent: stealthsurf-merlin/$ADDON_VERSION" \
      --connect-timeout 15 --max-time 45 2>/dev/null) || http_code="000"
  fi

  rm -f "$tmp_headers"

  if [ "$http_code" = "000" ]; then
    ss_error "API request failed (network): $method $path"
    rm -f "$tmp_body"
    return 1
  fi

  if ! jq -e . "$tmp_body" >/dev/null 2>&1; then
    ss_error "API returned non-JSON (HTTP $http_code): $method $path"
    rm -f "$tmp_body"
    return 1
  fi

  if [ "$http_code" -ge 400 ] 2>/dev/null; then
    ss_error "API HTTP $http_code: $(jq -r '.message // .errorCode // "unknown"' "$tmp_body")"
    cat "$tmp_body"
    rm -f "$tmp_body"
    return 1
  fi

  if jq -e '.status == false' "$tmp_body" >/dev/null 2>&1; then
    ss_error "API error: $(jq -r '.message // "unknown"' "$tmp_body")"
    cat "$tmp_body"
    rm -f "$tmp_body"
    return 1
  fi

  cat "$tmp_body"
  rm -f "$tmp_body"
  return 0
}

ss_api_verify_key() {
  local resp
  resp=$(ss_api GET /profile) || return 1
  printf '%s' "$resp" | jq '.data' >"$SS_CACHE_PROFILE"
  ss_ok "API key accepted for user $(printf '%s' "$resp" | jq -r '.data.id // .data.user_id // "ok"')"
  printf '%s' "$resp"
}

ss_api_sync_configs() {
  local resp
  resp=$(ss_api GET '/configs?limit=100&offset=0') || return 1
  printf '%s' "$resp" | jq '.data // []' >"$SS_CACHE_CONFIGS"
  ss_ok "Synced $(jq 'length' "$SS_CACHE_CONFIGS") configs"
  printf '%s' "$resp"
}

ss_api_sync_locations() {
  local resp
  resp=$(ss_api GET /locations) || return 1
  printf '%s' "$resp" | jq '.data // []' >"$SS_CACHE_LOCATIONS"
  ss_ok "Synced locations"
  printf '%s' "$resp"
}

ss_api_update_settings() {
  local config_id="$1"
  local body="$2"
  local resp
  [ -n "$config_id" ] && [ -n "$body" ] || {
    ss_error "usage: update-settings <config_id> '<json body>'"
    return 1
  }
  resp=$(ss_api PATCH "/configs/${config_id}/settings" "$body") || return 1
  ss_ok "Updated settings for config $config_id"
  # Refresh cache entry
  ss_api_sync_configs >/dev/null
  printf '%s' "$resp"
}

ss_cache_get_config() {
  local config_id="$1"
  [ -f "$SS_CACHE_CONFIGS" ] || ss_api_sync_configs >/dev/null || return 1
  jq -c --argjson id "$config_id" 'map(select(. != null and .id == $id)) | first // empty' "$SS_CACHE_CONFIGS"
}
