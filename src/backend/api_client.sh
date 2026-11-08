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
  SS_LAST_SYNC=$(date +%s)
  ss_save_conf
  ss_write_state 2>/dev/null || true
  ss_activity "sync.done" "configs=$(jq 'length' "$SS_CACHE_CONFIGS" 2>/dev/null || echo 0) subs=$(jq 'length' "$SS_CACHE_SUBSCRIPTIONS" 2>/dev/null || echo 0) ts=$SS_LAST_SYNC"
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

ss_mask_email() {
  # Mask local-part for UI cache (never log full addresses with keys)
  local email="$1"
  local local_part domain
  case "$email" in
  *@*)
    local_part="${email%%@*}"
    domain="${email#*@}"
    if [ "${#local_part}" -le 2 ]; then
      printf '%s@%s' "*" "$domain"
    else
      printf '%s***%s@%s' "$(printf '%s' "$local_part" | cut -c1-2)" "$(printf '%s' "$local_part" | tail -c 1)" "$domain"
    fi
    ;;
  *)
    printf '%s' "${email:-}"
    ;;
  esac
}

ss_api_key_meta() {
  # Resolve label / fingerprint / tail for a stored API key (no full key echoed)
  local key="$1"
  local label key_fp key_tail
  key_fp=$(printf '%s' "$key" | awk -F_ '{print $2}')
  key_tail=$(printf '%s' "$key" | tail -c 8)
  label=""
  if [ -f "$SS_CACHE_KEYS" ]; then
    label=$(jq -r --arg k "$key" '
      (map(select(.key == $k)) | first | .label // empty) // empty
    ' "$SS_CACHE_KEYS" 2>/dev/null)
  fi
  [ -n "$label" ] || {
    if [ "$key" = "$SS_API_KEY" ]; then
      label="primary"
    else
      label=""
    fi
  }
  jq -nc \
    --arg label "$label" \
    --arg key_fp "${key_fp:-}" \
    --arg key_tail "${key_tail:-}" \
    '{label:$label, key_fp:$key_fp, key_tail:$key_tail}'
}

ss_api_balance_one() {
  # Fetch balance fields for one API key via GET /profile. Never prints the key.
  # stdout: single JSON object {ok, label, key_fp, key_tail, user_id, email, balance, referral_balance, currency, error}
  local key="$1"
  local meta resp data err_msg balance referral email uid
  meta=$(ss_api_key_meta "$key")
  err_msg=""
  # Capture both stdout (error body may be printed on HTTP fail) and suppress noisy stderr
  if ! resp=$(ss_api_with_key "$key" GET /profile 2>/dev/null); then
    err_msg=$(printf '%s' "$resp" | jq -r '.message // .errorCode // .error // empty' 2>/dev/null)
    [ -n "$err_msg" ] || err_msg="API request failed"
    err_msg=$(ss_api_friendly_error "$err_msg")
    # Never echo raw API key / token fragments into the cache
    err_msg=$(printf '%s' "$err_msg" | sed 's/stlth_[A-Za-z0-9_]*/stlth_***/g' | cut -c1-160)
    jq -nc \
      --argjson meta "$meta" \
      --arg error "$err_msg" \
      '$meta + {ok:false, user_id:null, email:null, balance:null, referral_balance:null, currency:"RUB", error:$error}'
    return 1
  fi
  data=$(printf '%s' "$resp" | jq -c '.data // {}')
  # Refresh primary profile cache only for the active primary key
  if [ "$key" = "$SS_API_KEY" ]; then
    printf '%s' "$data" >"$SS_CACHE_PROFILE"
  fi
  balance=$(printf '%s' "$data" | jq -r '.balance // empty')
  referral=$(printf '%s' "$data" | jq -r '.referral_balance // empty')
  email=$(printf '%s' "$data" | jq -r '.email // empty')
  uid=$(printf '%s' "$data" | jq -r '.id // empty')
  if [ -z "$balance" ] && [ -z "$referral" ] && [ -z "$uid" ]; then
    jq -nc \
      --argjson meta "$meta" \
      --arg error "Профиль без поля balance" \
      '$meta + {ok:false, user_id:null, email:null, balance:null, referral_balance:null, currency:"RUB", error:$error}'
    return 1
  fi
  email=$(ss_mask_email "$email")
  jq -nc \
    --argjson meta "$meta" \
    --argjson balance "${balance:-0}" \
    --argjson referral "${referral:-0}" \
    --arg email "$email" \
    --argjson uid "${uid:-null}" \
    '$meta + {
      ok:true,
      user_id: $uid,
      email: (if $email == "" then null else $email end),
      balance: $balance,
      referral_balance: $referral,
      currency: "RUB",
      error: null
    }'
  return 0
}

ss_api_fetch_balances() {
  # Refresh balances.json for every configured StealthSurf API key (GET /profile).
  # Cache never stores full API keys — only label / fingerprint / tail + amounts.
  local key tmp entry any=0 ok_n=0 fail_n=0
  local force="${1:-0}"
  local now age
  ss_ensure_dirs
  now=$(date +%s)

  # Soft cache: skip network if fresh (<120s) unless force=1
  if [ "$force" != "1" ] && [ -f "$SS_CACHE_BALANCES" ]; then
    age=$(jq -r --argjson now "$now" '($now - (.fetched_at // 0))' "$SS_CACHE_BALANCES" 2>/dev/null || echo 99999)
    if [ -n "$age" ] && [ "$age" -lt 120 ] 2>/dev/null; then
      ss_info "Balances cache fresh (${age}s) — skip refresh"
      cat "$SS_CACHE_BALANCES"
      return 0
    fi
  fi

  tmp="$ADDON_TMP_DIR/balances.merge.$$"
  echo '[]' >"$tmp"
  for key in $(ss_all_api_keys); do
    [ -n "$key" ] || continue
    any=1
    if entry=$(ss_api_balance_one "$key"); then
      ok_n=$((ok_n + 1))
    else
      fail_n=$((fail_n + 1))
      # ss_api_balance_one still prints a JSON error object on failure
      [ -n "$entry" ] || entry='{"ok":false,"error":"unknown","currency":"RUB"}'
    fi
    jq --argjson add "$entry" '. + [$add]' "$tmp" >"$tmp.n" && mv "$tmp.n" "$tmp"
  done

  if [ "$any" -ne 1 ]; then
    jq -nc --argjson ts "$now" \
      '{fetched_at:$ts, keys:[], total_balance:0, total_referral:0, currency:"RUB", ok:0, fail:0, message:"Нет сохранённых API-ключей"}' \
      >"$SS_CACHE_BALANCES"
    ln -sf "$SS_CACHE_BALANCES" "$ADDON_WEB_DIR/balances.json" 2>/dev/null || true
    cat "$SS_CACHE_BALANCES"
    return 0
  fi

  jq -nc \
    --argjson ts "$now" \
    --slurpfile keys "$tmp" \
    --argjson ok "$ok_n" \
    --argjson fail "$fail_n" '
      ($keys[0] // []) as $k |
      {
        fetched_at: $ts,
        keys: $k,
        total_balance: ([ $k[] | select(.ok == true) | (.balance // 0) ] | add // 0),
        total_referral: ([ $k[] | select(.ok == true) | (.referral_balance // 0) ] | add // 0),
        currency: "RUB",
        ok: $ok,
        fail: $fail,
        message: (
          if $fail == 0 then "Баланс обновлён"
          elif $ok == 0 then "Не удалось получить баланс"
          else "Баланс частично обновлён"
          end
        )
      }
    ' >"$SS_CACHE_BALANCES"
  rm -f "$tmp" "$tmp.n"
  ln -sf "$SS_CACHE_BALANCES" "$ADDON_WEB_DIR/balances.json" 2>/dev/null || true
  if [ "$ok_n" -gt 0 ]; then
    ss_ok "Balances: ok=$ok_n fail=$fail_n total=$(jq -r '.total_balance' "$SS_CACHE_BALANCES")₽"
  else
    ss_warn "Balances: all keys failed ($fail_n)"
  fi
  cat "$SS_CACHE_BALANCES"
  [ "$ok_n" -gt 0 ]
}
