#!/bin/sh

ss_api_with_key() {
  # ss_api_with_key KEY METHOD PATH [JSON_BODY]
  local api_key="$1"
  local method="$2"
  local path="$3"
  local body="$4"
  local tmp_headers tmp_body http_code url retry_after

  [ -n "$api_key" ] || {
    ss_error "API key empty"
    return 1
  }
  ss_ensure_dirs

  url="${SS_API_BASE}${path}"
  tmp_headers="$ADDON_TMP_DIR/api.headers.$$"
  tmp_body="$ADDON_TMP_DIR/api.body.$$"

  if [ -n "$body" ]; then
    http_code=$(curl -sS -o "$tmp_body" -D "$tmp_headers" -w '%{http_code}' \
      -X "$method" "$url" \
      -H "Authorization: Bearer $api_key" \
      -H "Content-Type: application/json" \
      -H "Accept: application/json" \
      -H "User-Agent: stealthsurf-merlin/$ADDON_VERSION" \
      --connect-timeout 15 --max-time 45 \
      -d "$body" 2>/dev/null) || http_code="000"
  else
    http_code=$(curl -sS -o "$tmp_body" -D "$tmp_headers" -w '%{http_code}' \
      -X "$method" "$url" \
      -H "Authorization: Bearer $api_key" \
      -H "Accept: application/json" \
      -H "User-Agent: stealthsurf-merlin/$ADDON_VERSION" \
      --connect-timeout 15 --max-time 45 2>/dev/null) || http_code="000"
  fi

  if [ "$http_code" = "429" ]; then
    retry_after=$(grep -i '^retry-after:' "$tmp_headers" 2>/dev/null | awk '{print $2}' | tr -d '\r')
    ss_error "API rate-limit (HTTP 429). Подождите ${retry_after:-60}с и повторите. Лимит StealthSurf: ~60 запросов/мин."
    rm -f "$tmp_headers" "$tmp_body"
    return 1
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

ss_api() {
  # ss_api METHOD PATH [JSON_BODY] — uses primary key
  ss_require_key || return 1
  ss_api_with_key "$SS_API_KEY" "$1" "$2" "$3"
}

ss_api_keys_store_add() {
  local key="$1"
  local label="${2:-}"
  ss_ensure_dirs
  jq --arg key "$key" --arg label "$label" --argjson ts "$(date +%s)" '
    (map(select(.key != $key))) + [{key:$key, label:$label, added_at:$ts}]
  ' "$SS_CACHE_KEYS" >"$SS_CACHE_KEYS.tmp" && mv "$SS_CACHE_KEYS.tmp" "$SS_CACHE_KEYS"
}

ss_api_keys_store_remove() {
  local key="$1"
  jq --arg key "$key" 'map(select(.key != $key))' "$SS_CACHE_KEYS" >"$SS_CACHE_KEYS.tmp" && mv "$SS_CACHE_KEYS.tmp" "$SS_CACHE_KEYS"
  if [ "$SS_API_KEY" = "$key" ]; then
    SS_API_KEY=$(jq -r '.[0].key // empty' "$SS_CACHE_KEYS")
  fi
  SS_API_KEYS=$(jq -r '.[].key' "$SS_CACHE_KEYS" | tr '\n' ' ')
  ss_save_conf
}

ss_api_add_key() {
  local key="$1"
  local label="$2"
  [ -n "$key" ] || {
    ss_error "usage: add-key <stlth_...> [label]"
    return 1
  }
  if ! ss_api_with_key "$key" GET /profile >/dev/null; then
    ss_error "Key rejected by API"
    return 1
  fi
  ss_api_keys_store_add "$key" "$label"
  if [ -z "$SS_API_KEY" ]; then
    SS_API_KEY="$key"
  fi
  SS_API_KEYS=$(jq -r '.[].key' "$SS_CACHE_KEYS" | tr '\n' ' ')
  ss_save_conf
  ss_ok "API key added"
}

ss_api_verify_key() {
  local resp
  resp=$(ss_api GET /profile) || return 1
  printf '%s' "$resp" | jq '.data' >"$SS_CACHE_PROFILE"
  ss_api_keys_store_add "$SS_API_KEY" "primary"
  ss_ok "API key accepted for user $(printf '%s' "$resp" | jq -r '.data.id // .data.user_id // "ok"')"
  printf '%s' "$resp"
}

ss_api_sync_configs_one() {
  local key="$1"
  local resp
  resp=$(ss_api_with_key "$key" GET '/configs?limit=100&offset=0') || return 1
  printf '%s' "$resp" | jq --arg key_fp "$(printf '%s' "$key" | awk -F_ '{print $2}')" '
    (.data // []) | map(select(. != null) | . + {_api_key_fp: $key_fp})
  '
}

ss_api_sync_configs() {
  local key merged tmp
  ss_ensure_dirs
  tmp="$ADDON_TMP_DIR/configs.merge.$$"
  echo '[]' >"$tmp"
  local any=0
  for key in $(ss_all_api_keys); do
    [ -n "$key" ] || continue
    if merged=$(ss_api_sync_configs_one "$key"); then
      any=1
      jq --argjson add "$merged" '. + $add | unique_by(.id)' "$tmp" >"$tmp.n" && mv "$tmp.n" "$tmp"
    else
      ss_warn "Sync failed for key …$(printf '%s' "$key" | tail -c 6)"
    fi
  done
  if [ "$any" -ne 1 ]; then
    ss_error "No configs synced"
    rm -f "$tmp" "$tmp.n"
    return 1
  fi
  mv "$tmp" "$SS_CACHE_CONFIGS"
  # Symlink for UI
  ln -sf "$SS_CACHE_CONFIGS" "$ADDON_WEB_DIR/configs.json" 2>/dev/null || true
  ss_ok "Synced $(jq 'length' "$SS_CACHE_CONFIGS") configs across keys"
  cat "$SS_CACHE_CONFIGS"
}

ss_api_sync_subscriptions() {
  local key tmp items resp
  ss_ensure_dirs
  tmp="$ADDON_TMP_DIR/subs.merge.$$"
  echo '[]' >"$tmp"
  for key in $(ss_all_api_keys); do
    [ -n "$key" ] || continue
    resp=$(ss_api_with_key "$key" GET '/profile/custom-subscriptions?limit=100&offset=0') || continue
    # Normalize list
    items=$(printf '%s' "$resp" | jq '
      (.data // []) |
      if type == "array" then . elif .items then .items else [.] end
    ')
    jq --argjson add "$items" '. + $add' "$tmp" >"$tmp.n" && mv "$tmp.n" "$tmp"

    # Try to fetch items for each subscription id
    printf '%s' "$items" | jq -r '.[].id // empty' 2>/dev/null | while read -r sid; do
      [ -n "$sid" ] || continue
      sub_items=$(ss_api_with_key "$key" GET "/profile/custom-subscriptions/${sid}/items?limit=100&offset=0" 2>/dev/null) || continue
      printf '%s' "$sub_items" | jq --argjson sid "$sid" '
        (.data // []) | map(. + {_subscription_id: $sid})
      ' >"$ADDON_TMP_DIR/subitems.${sid}.json" 2>/dev/null || true
    done
  done
  mv "$tmp" "$SS_CACHE_SUBSCRIPTIONS"
  ln -sf "$SS_CACHE_SUBSCRIPTIONS" "$ADDON_WEB_DIR/subscriptions.json" 2>/dev/null || true
  ss_ok "Synced custom subscriptions ($(jq 'length' "$SS_CACHE_SUBSCRIPTIONS"))"
  cat "$SS_CACHE_SUBSCRIPTIONS"
}

ss_api_sync_locations() {
  local resp
  resp=$(ss_api GET /locations) || return 1
  printf '%s' "$resp" | jq '.data // []' >"$SS_CACHE_LOCATIONS"
  ln -sf "$SS_CACHE_LOCATIONS" "$ADDON_WEB_DIR/locations.json" 2>/dev/null || true
  ss_ok "Synced locations"
  printf '%s' "$resp"
}

ss_enabled_configs_fingerprint() {
  # Hash of provider fields that affect dataplane for enabled (or active) configs.
  # Used to detect site-side changes (protocol/location/URL/xray/awg) after sync.
  local ids="${SS_ENABLED_OUTBOUNDS:-}"
  [ -n "$ids" ] || ids="${SS_ACTIVE_CONFIG_ID:-}"
  [ -f "$SS_CACHE_CONFIGS" ] || {
    echo "none"
    return 0
  }
  if [ -z "$ids" ]; then
    echo "none"
    return 0
  fi
  jq -c --arg ids "$ids" '
    ($ids | split(" ") | map(select(length > 0) | (tonumber? // .))) as $want |
    [ .[]
      | select(. != null)
      | . as $c
      | select(($want | index($c.id)) != null)
      | {id: $c.id, protocol: $c.protocol, location_id: $c.location_id, server_id: $c.server_id,
         connection_url: $c.connection_url, xray_config: $c.xray_config, awg_config: $c.awg_config,
         title: $c.title, is_online: $c.is_online}
    ] | sort_by(.id)
  ' "$SS_CACHE_CONFIGS" | {
    if command -v md5sum >/dev/null 2>&1; then md5sum
    elif command -v md5 >/dev/null 2>&1; then md5
    else cksum
    fi
  } | awk '{print $1}'
}

ss_apply_provider_changes() {
  # After a successful API sync: rebuild router dataplane if enabled configs changed.
  # Fingerprint file is updated only after a successful apply path so a failed rebuild
  # is retried on the next sync.
  local prev new fpfile
  ss_ensure_dirs
  fpfile="$ADDON_DATA_DIR/enabled-configs.fp"
  prev=$(cat "$fpfile" 2>/dev/null || echo "")
  new=$(ss_enabled_configs_fingerprint)

  if [ -z "$SS_ENABLED_OUTBOUNDS" ] && [ -z "$SS_ACTIVE_CONFIG_ID" ]; then
    printf '%s\n' "$new" >"$fpfile"
    ss_info "Sync OK — нет включённых outbound (только каталог обновлён)"
    ss_activity "sync.catalog_only" "fp=$new"
    return 0
  fi

  if [ -n "$prev" ] && [ "$prev" = "$new" ]; then
    ss_info "Sync OK — настройки включённых конфигов не изменились"
    ss_activity "sync.unchanged" "fp=$new"
    return 0
  fi

  ss_info "Изменения у провайдера обнаружены — пересобираю Xray/outbound…"
  ss_activity "sync.changed" "prev=${prev:-none} new=$new"
  # Rebuild whenever we already have a dataplane or user marked desired-running
  if ss_xray_running || { type ss_desired_is_set >/dev/null 2>&1 && ss_desired_is_set; } || [ -f "$XRAY_CONFIG_FILE" ]; then
    ss_rebuild_and_restart || {
      ss_warn "Sync скачал новые URL, но rebuild не удался — нажмите Apply/Restart"
      return 1
    }
    printf '%s\n' "$new" >"$fpfile"
    ss_ok "Dataplane обновлён под новые connection_url / settings"
  else
    printf '%s\n' "$new" >"$fpfile"
    ss_info "Новые URL в кэше; запустите start/apply чтобы применить на роутере"
  fi
  return 0
}

ss_api_sync_all() {
  ss_activity "sync.start" "keys=$(ss_all_api_keys | wc -l | tr -d ' ')"
  if ! ss_api_sync_configs >/dev/null; then
    ss_activity "sync.fail" "configs sync failed"
    return 1
  fi
  ss_api_sync_locations >/dev/null || true
  ss_api_sync_subscriptions >/dev/null || true
  ss_activity "sync.done" "configs=$(jq 'length' "$SS_CACHE_CONFIGS" 2>/dev/null || echo 0) subs=$(jq 'length' "$SS_CACHE_SUBSCRIPTIONS" 2>/dev/null || echo 0)"
  ss_ok "Full sync complete"
}

ss_sync_from_provider() {
  # Pull catalog from StealthSurf API and apply changes to enabled outbounds
  ss_api_sync_all || return 1
  ss_apply_provider_changes
}

ss_api_update_settings() {
  local config_id="$1"
  local body="$2"
  local resp
  [ -n "$config_id" ] && [ -n "$body" ] || {
    ss_error "usage: update-settings <config_id> '<json body>'"
    return 1
  }
  # Official API requires location_id + protocol; optional: use_xhttp, use_grpc, use_warp,
  # use_salamander, disable_reality, dns_preset, server_id, …
  resp=$(ss_api PATCH "/configs/${config_id}/settings" "$body") || return 1
  ss_ok "Updated settings for config $config_id"
  ss_api_sync_configs >/dev/null || return 1
  # If this config is enabled, refresh dataplane with new connection_url from API
  if echo " ${SS_ENABLED_OUTBOUNDS} ${SS_ACTIVE_CONFIG_ID} " | grep -q " ${config_id} "; then
    ss_apply_provider_changes || true
  fi
  printf '%s' "$resp"
}

ss_cache_get_config() {
  local config_id="$1"
  [ -f "$SS_CACHE_CONFIGS" ] || ss_api_sync_configs >/dev/null || return 1
  jq -c --argjson id "$config_id" 'map(select(. != null and .id == $id)) | first // empty' "$SS_CACHE_CONFIGS"
}

ss_api_friendly_error() {
  # Map common messages for UI
  local msg="$1"
  case "$msg" in
  *429* | *rate*)
    echo "Превышен лимит API (≈60 запросов/мин). Подождите минуту."
    ;;
  *access\ denied* | *401*)
    echo "API-ключ отклонён или нет доступа к методу."
    ;;
  *user\ banned*)
    echo "Аккаунт заблокирован у провайдера."
    ;;
  *)
    echo "$msg"
    ;;
  esac
}
