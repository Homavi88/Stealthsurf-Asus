#!/bin/sh
# shellcheck disable=SC2034
# StealthSurf provider API: keys, balances, catalog sync, import into Xray outbounds.

ss_api_ensure_caches() {
    mkdir -p "$ADDON_SHARE_DIR" "$ADDON_TMP_DIR" "$ADDON_WEB_DIR" 2>/dev/null
    [ -f "$SS_CACHE_KEYS" ] || echo '[]' >"$SS_CACHE_KEYS"
    [ -f "$SS_CACHE_BALANCES" ] || echo '{"fetched_at":0,"keys":[],"total_balance":0,"total_referral":0,"currency":"RUB"}' >"$SS_CACHE_BALANCES"
    [ -f "$SS_CACHE_CONFIGS" ] || echo '[]' >"$SS_CACHE_CONFIGS"
    [ -f "$SS_CACHE_LOCATIONS" ] || echo '[]' >"$SS_CACHE_LOCATIONS"
    [ -f "$SS_CACHE_PROFILE" ] || echo '{}' >"$SS_CACHE_PROFILE"
    [ -f "$SS_CACHE_SUBSCRIPTIONS" ] || echo '[]' >"$SS_CACHE_SUBSCRIPTIONS"
    ln -sf "$SS_CACHE_KEYS" "$ADDON_WEB_DIR/api_keys.json" 2>/dev/null || true
    ln -sf "$SS_CACHE_BALANCES" "$ADDON_WEB_DIR/balances.json" 2>/dev/null || true
    ln -sf "$SS_CACHE_CONFIGS" "$ADDON_WEB_DIR/ss_configs.json" 2>/dev/null || true
    ln -sf "$SS_CACHE_LOCATIONS" "$ADDON_WEB_DIR/ss_locations.json" 2>/dev/null || true
    ln -sf "$SS_CACHE_PROFILE" "$ADDON_WEB_DIR/ss_profile.json" 2>/dev/null || true
    ln -sf "$SS_CACHE_SUBSCRIPTIONS" "$ADDON_WEB_DIR/ss_subscriptions.json" 2>/dev/null || true
}

ss_api_migrate_legacy_keys() {
    # Import keys from StealthSurf 1.0.x conf if present and current store is empty.
    local legacy="/opt/etc/stealthsurf.conf"
    local key keys
    ss_api_ensure_caches
    if [ "$(jq 'length' "$SS_CACHE_KEYS" 2>/dev/null || echo 0)" -gt 0 ]; then
        return 0
    fi
    [ -f "$legacy" ] || return 0
    # shellcheck disable=SC1090
    . "$legacy" 2>/dev/null || true
    for key in $SS_API_KEY $SS_API_KEYS; do
        [ -n "$key" ] || continue
        ss_api_keys_store_add "$key" "migrated" || true
    done
    if [ -n "$SS_API_KEY" ]; then
        update_xrayui_config "SS_API_KEY" "$SS_API_KEY"
        update_xrayui_config "SS_API_KEYS" "$SS_API_KEYS"
        update_xrayui_config "SS_API_BASE" "${SS_API_BASE:-https://api.stealthsurf.net}"
        log_ok "Migrated StealthSurf API keys from 1.0.x conf"
    fi
}

ss_api_persist_keys() {
    SS_API_KEYS=$(jq -r '.[].key' "$SS_CACHE_KEYS" 2>/dev/null | tr '\n' ' ')
    SS_API_KEY=$(jq -r '.[0].key // empty' "$SS_CACHE_KEYS" 2>/dev/null)
    update_xrayui_config "SS_API_KEY" "$SS_API_KEY"
    update_xrayui_config "SS_API_KEYS" "$SS_API_KEYS"
    update_xrayui_config "SS_API_BASE" "${SS_API_BASE:-https://api.stealthsurf.net}"
}

ss_all_api_keys() {
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

ss_require_key() {
    load_xrayui_config
    if [ -z "$SS_API_KEY" ] && [ -z "$SS_API_KEYS" ]; then
        if [ -f "$SS_CACHE_KEYS" ]; then
            SS_API_KEY=$(jq -r '.[0].key // empty' "$SS_CACHE_KEYS")
        fi
    fi
    if [ -z "$SS_API_KEY" ] && [ -n "$SS_API_KEYS" ]; then
        SS_API_KEY=$(printf '%s' "$SS_API_KEYS" | awk '{print $1}')
    fi
    if [ -z "$SS_API_KEY" ]; then
        log_error "API key is not set"
        return 1
    fi
    return 0
}

ss_api_with_key() {
    local api_key="$1"
    local method="$2"
    local path="$3"
    local body="$4"
    local tmp_headers tmp_body http_code url retry_after

    [ -n "$api_key" ] || {
        log_error "API key empty"
        return 1
    }
    ss_api_ensure_caches
    SS_API_BASE="${SS_API_BASE:-https://api.stealthsurf.net}"

    url="${SS_API_BASE}${path}"
    tmp_headers="$ADDON_TMP_DIR/ss_api.headers.$$"
    tmp_body="$ADDON_TMP_DIR/ss_api.body.$$"

    if [ -n "$body" ]; then
        http_code=$(curl -sS -o "$tmp_body" -D "$tmp_headers" -w '%{http_code}' \
            -X "$method" "$url" \
            -H "Authorization: Bearer $api_key" \
            -H "Content-Type: application/json" \
            -H "Accept: application/json" \
            -H "User-Agent: stealthsurf-merlin/$XRAYUI_VERSION" \
            --connect-timeout 15 --max-time 45 \
            -d "$body" 2>/dev/null) || http_code="000"
    else
        http_code=$(curl -sS -o "$tmp_body" -D "$tmp_headers" -w '%{http_code}' \
            -X "$method" "$url" \
            -H "Authorization: Bearer $api_key" \
            -H "Accept: application/json" \
            -H "User-Agent: stealthsurf-merlin/$XRAYUI_VERSION" \
            --connect-timeout 15 --max-time 45 2>/dev/null) || http_code="000"
    fi

    if [ "$http_code" = "429" ]; then
        retry_after=$(grep -i '^retry-after:' "$tmp_headers" 2>/dev/null | awk '{print $2}' | tr -d '\r')
        log_error "API rate-limit (HTTP 429). Wait ${retry_after:-60}s."
        rm -f "$tmp_headers" "$tmp_body"
        return 1
    fi
    rm -f "$tmp_headers"

    if [ "$http_code" = "000" ]; then
        log_error "API request failed (network): $method $path"
        rm -f "$tmp_body"
        return 1
    fi

    if ! jq -e . "$tmp_body" >/dev/null 2>&1; then
        log_error "API returned non-JSON (HTTP $http_code): $method $path"
        rm -f "$tmp_body"
        return 1
    fi

    if [ "$http_code" -ge 400 ] 2>/dev/null; then
        log_error "API HTTP $http_code: $(jq -r '.message // .errorCode // "unknown"' "$tmp_body")"
        cat "$tmp_body"
        rm -f "$tmp_body"
        return 1
    fi

    if jq -e '.status == false' "$tmp_body" >/dev/null 2>&1; then
        log_error "API error: $(jq -r '.message // "unknown"' "$tmp_body")"
        cat "$tmp_body"
        rm -f "$tmp_body"
        return 1
    fi

    cat "$tmp_body"
    rm -f "$tmp_body"
    return 0
}

ss_api() {
    ss_require_key || return 1
    ss_api_with_key "$SS_API_KEY" "$1" "$2" "$3"
}

ss_api_keys_store_add() {
    local key="$1"
    local label="${2:-}"
    ss_api_ensure_caches
    jq --arg key "$key" --arg label "$label" --argjson ts "$(date +%s)" '
    (map(select(.key != $key))) + [{key:$key, label:$label, added_at:$ts}]
  ' "$SS_CACHE_KEYS" >"$SS_CACHE_KEYS.tmp" && mv "$SS_CACHE_KEYS.tmp" "$SS_CACHE_KEYS"
}

ss_api_keys_store_remove() {
    local key="$1"
    ss_api_ensure_caches
    jq --arg key "$key" 'map(select(.key != $key))' "$SS_CACHE_KEYS" >"$SS_CACHE_KEYS.tmp" && mv "$SS_CACHE_KEYS.tmp" "$SS_CACHE_KEYS"
    ss_api_persist_keys
}

ss_api_add_key() {
    local key="$1"
    local label="$2"
    [ -n "$key" ] || {
        log_error "usage: add-key <stlth_...> [label]"
        return 1
    }
    if ! ss_api_with_key "$key" GET /profile >/dev/null; then
        log_error "Key rejected by API"
        return 1
    fi
    ss_api_keys_store_add "$key" "$label"
    ss_api_persist_keys
    log_ok "API key added"
}

ss_api_set_primary_key() {
    local key="$1"
    local label="${2:-primary}"
    [ -n "$key" ] || return 1
    if ! ss_api_with_key "$key" GET /profile >/dev/null; then
        log_error "Key rejected by API"
        return 1
    fi
    ss_api_keys_store_add "$key" "$label"
    # Move to front
    jq --arg key "$key" '([.[] | select(.key == $key)] + [.[] | select(.key != $key)])' "$SS_CACHE_KEYS" >"$SS_CACHE_KEYS.tmp" && mv "$SS_CACHE_KEYS.tmp" "$SS_CACHE_KEYS"
    ss_api_persist_keys
    log_ok "Primary API key set"
}

ss_mask_email() {
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
    local key="$1"
    local label key_fp key_tail
    key_fp=$(printf '%s' "$key" | awk -F_ '{print $2}')
    key_tail=$(printf '%s' "$key" | tail -c 8)
    label=""
    if [ -f "$SS_CACHE_KEYS" ]; then
        label=$(jq -r --arg k "$key" '(map(select(.key == $k)) | first | .label // empty) // empty' "$SS_CACHE_KEYS" 2>/dev/null)
    fi
    [ -n "$label" ] || label=$([ "$key" = "$SS_API_KEY" ] && echo primary || echo "")
    jq -nc --arg label "$label" --arg key_fp "${key_fp:-}" --arg key_tail "${key_tail:-}" \
        '{label:$label, key_fp:$key_fp, key_tail:$key_tail}'
}

ss_api_balance_one() {
    local key="$1"
    local meta resp data err_msg balance referral email uid
    meta=$(ss_api_key_meta "$key")
    if ! resp=$(ss_api_with_key "$key" GET /profile 2>/dev/null); then
        err_msg=$(printf '%s' "$resp" | jq -r '.message // .errorCode // .error // empty' 2>/dev/null)
        [ -n "$err_msg" ] || err_msg="API request failed"
        err_msg=$(printf '%s' "$err_msg" | sed 's/stlth_[A-Za-z0-9_]*/stlth_***/g' | cut -c1-160)
        jq -nc --argjson meta "$meta" --arg error "$err_msg" \
            '$meta + {ok:false, user_id:null, email:null, balance:null, referral_balance:null, currency:"RUB", error:$error}'
        return 1
    fi
    data=$(printf '%s' "$resp" | jq -c '.data // {}')
    if [ "$key" = "$SS_API_KEY" ]; then
        printf '%s' "$data" >"$SS_CACHE_PROFILE"
    fi
    balance=$(printf '%s' "$data" | jq -r '.balance // empty')
    referral=$(printf '%s' "$data" | jq -r '.referral_balance // empty')
    email=$(ss_mask_email "$(printf '%s' "$data" | jq -r '.email // empty')")
    uid=$(printf '%s' "$data" | jq -r '.id // empty')
    if [ -z "$balance" ] && [ -z "$referral" ] && [ -z "$uid" ]; then
        jq -nc --argjson meta "$meta" --arg error "Profile without balance" \
            '$meta + {ok:false, user_id:null, email:null, balance:null, referral_balance:null, currency:"RUB", error:$error}'
        return 1
    fi
    jq -nc \
        --argjson meta "$meta" \
        --argjson balance "${balance:-0}" \
        --argjson referral "${referral:-0}" \
        --arg email "$email" \
        --argjson uid "${uid:-null}" \
        '$meta + {ok:true, user_id:$uid, email:(if $email=="" then null else $email end), balance:$balance, referral_balance:$referral, currency:"RUB", error:null}'
    return 0
}

ss_api_fetch_balances() {
    local key tmp entry any=0 ok_n=0 fail_n=0
    local force="${1:-0}"
    local now age
    load_xrayui_config
    ss_api_ensure_caches
    now=$(date +%s)

    if [ "$force" != "1" ] && [ -f "$SS_CACHE_BALANCES" ]; then
        age=$(jq -r --argjson now "$now" '($now - (.fetched_at // 0))' "$SS_CACHE_BALANCES" 2>/dev/null || echo 99999)
        if [ -n "$age" ] && [ "$age" -lt 120 ] 2>/dev/null; then
            log_info "Balances cache fresh (${age}s)"
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
            [ -n "$entry" ] || entry='{"ok":false,"error":"unknown","currency":"RUB"}'
        fi
        jq --argjson add "$entry" '. + [$add]' "$tmp" >"$tmp.n" && mv "$tmp.n" "$tmp"
    done

    if [ "$any" -ne 1 ]; then
        jq -nc --argjson ts "$now" \
            '{fetched_at:$ts, keys:[], total_balance:0, total_referral:0, currency:"RUB", ok:0, fail:0, message:"No API keys saved"}' \
            >"$SS_CACHE_BALANCES"
        cat "$SS_CACHE_BALANCES"
        return 0
    fi

    jq -nc --argjson ts "$now" --slurpfile keys "$tmp" --argjson ok "$ok_n" --argjson fail "$fail_n" '
      ($keys[0] // []) as $k |
      {
        fetched_at: $ts,
        keys: $k,
        total_balance: ([ $k[] | select(.ok == true) | (.balance // 0) ] | add // 0),
        total_referral: ([ $k[] | select(.ok == true) | (.referral_balance // 0) ] | add // 0),
        currency: "RUB",
        ok: $ok,
        fail: $fail,
        message: (if $fail == 0 then "Balances updated" elif $ok == 0 then "Failed to fetch balances" else "Balances partially updated" end)
      }
    ' >"$SS_CACHE_BALANCES"
    rm -f "$tmp" "$tmp.n"
    ln -sf "$SS_CACHE_BALANCES" "$ADDON_WEB_DIR/balances.json" 2>/dev/null || true
    if [ "$ok_n" -gt 0 ]; then
        log_ok "Balances: ok=$ok_n fail=$fail_n total=$(jq -r '.total_balance' "$SS_CACHE_BALANCES") RUB"
    else
        log_warn "Balances: all keys failed ($fail_n)"
    fi
    cat "$SS_CACHE_BALANCES"
    [ "$ok_n" -gt 0 ]
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
    local key merged tmp any=0
    ss_api_ensure_caches
    tmp="$ADDON_TMP_DIR/configs.merge.$$"
    echo '[]' >"$tmp"
    for key in $(ss_all_api_keys); do
        [ -n "$key" ] || continue
        if merged=$(ss_api_sync_configs_one "$key"); then
            any=1
            jq --argjson add "$merged" '. + $add | unique_by(.id)' "$tmp" >"$tmp.n" && mv "$tmp.n" "$tmp"
        else
            log_warn "Sync failed for key …$(printf '%s' "$key" | tail -c 6)"
        fi
    done
    if [ "$any" -ne 1 ]; then
        log_error "No configs synced"
        rm -f "$tmp" "$tmp.n"
        return 1
    fi
    mv "$tmp" "$SS_CACHE_CONFIGS"
    ln -sf "$SS_CACHE_CONFIGS" "$ADDON_WEB_DIR/ss_configs.json" 2>/dev/null || true
    log_ok "Synced $(jq 'length' "$SS_CACHE_CONFIGS") StealthSurf configs"
    cat "$SS_CACHE_CONFIGS"
}

ss_api_sync_locations() {
    local resp
    resp=$(ss_api GET /locations) || return 1
    printf '%s' "$resp" | jq '.data // []' >"$SS_CACHE_LOCATIONS"
    ln -sf "$SS_CACHE_LOCATIONS" "$ADDON_WEB_DIR/ss_locations.json" 2>/dev/null || true
    log_ok "Synced locations"
}

ss_api_sync_subscriptions() {
    local key tmp items resp sid sub_items
    ss_api_ensure_caches
    tmp="$ADDON_TMP_DIR/subs.merge.$$"
    echo '[]' >"$tmp"
    for key in $(ss_all_api_keys); do
        [ -n "$key" ] || continue
        resp=$(ss_api_with_key "$key" GET '/profile/custom-subscriptions?limit=100&offset=0') || continue
        items=$(printf '%s' "$resp" | jq '(.data // []) | if type == "array" then . elif .items then .items else [.] end')
        jq --argjson add "$items" '. + $add' "$tmp" >"$tmp.n" && mv "$tmp.n" "$tmp"
        printf '%s' "$items" | jq -r '.[].id // empty' 2>/dev/null | while read -r sid; do
            [ -n "$sid" ] || continue
            sub_items=$(ss_api_with_key "$key" GET "/profile/custom-subscriptions/${sid}/items?limit=100&offset=0" 2>/dev/null) || continue
            printf '%s' "$sub_items" | jq --argjson sid "$sid" '(.data // []) | map(. + {_subscription_id: $sid})' \
                >"$ADDON_TMP_DIR/subitems.${sid}.json" 2>/dev/null || true
        done
    done
    mv "$tmp" "$SS_CACHE_SUBSCRIPTIONS"
    ln -sf "$SS_CACHE_SUBSCRIPTIONS" "$ADDON_WEB_DIR/ss_subscriptions.json" 2>/dev/null || true
    log_ok "Synced custom subscriptions ($(jq 'length' "$SS_CACHE_SUBSCRIPTIONS"))"
}

ss_api_sync_all() {
    load_xrayui_config
    ss_api_ensure_caches
    ss_api_sync_configs >/dev/null || return 1
    ss_api_sync_locations >/dev/null || true
    ss_api_sync_subscriptions >/dev/null || true
    SS_LAST_SYNC=$(date +%s)
    update_xrayui_config "SS_LAST_SYNC" "$SS_LAST_SYNC"
    ss_api_fetch_balances 1 >/dev/null || true
    log_ok "Full StealthSurf sync complete"
}

ss_api_import_config_to_xray() {
    # Import one StealthSurf config id into Xray outbounds (tag ss-<id>).
    local config_id="$1"
    local cfg link outbound tag title
    load_xrayui_config
    ss_api_ensure_caches
    [ -n "$config_id" ] || {
        log_error "usage: import-config <id>"
        return 1
    }
    [ -f "$SS_CACHE_CONFIGS" ] || ss_api_sync_configs >/dev/null || return 1
    cfg=$(jq -c --argjson id "$config_id" 'map(select(. != null and (.id|tostring) == ($id|tostring))) | first // empty' "$SS_CACHE_CONFIGS")
    [ -n "$cfg" ] || {
        log_error "Config $config_id not in catalog — sync first"
        return 1
    }
    link=$(printf '%s' "$cfg" | jq -r '.connection_url // empty')
    title=$(printf '%s' "$cfg" | jq -r '.title // .name // ("ss-" + (.id|tostring))')
    tag="ss-$config_id"
    if [ -z "$link" ]; then
        # Prefer provider-ready xray outbound fragment when URL missing
        if printf '%s' "$cfg" | jq -e '.xray_config' >/dev/null 2>&1; then
            outbound=$(printf '%s' "$cfg" | jq -c --arg tag "$tag" --arg title "$title" '
                (.xray_config | if type=="string" then (try fromjson catch .) else . end) as $x |
                (if ($x|type)=="object" and ($x.outbounds|type)=="array" then $x.outbounds[0]
                 elif ($x|type)=="object" and ($x.protocol != null) then $x
                 else empty end) | select(. != null) | . + {tag:$tag, _stealthsurf:true, _ss_title:$title}
            ')
        fi
    else
        outbound=$(subscription_parse_link_to_outbound "$link") || outbound=""
        if [ -n "$outbound" ]; then
            outbound=$(printf '%s' "$outbound" | jq -c --arg tag "$tag" --arg title "$title" '. + {tag:$tag, _stealthsurf:true, _ss_title:$title}')
        fi
    fi
    [ -n "$outbound" ] || {
        log_error "Could not parse connection for config $config_id"
        return 1
    }

    ensure_xray_scaffold
    # Upsert outbound; keep freedom/direct first; set catch-all default route to this proxy
    jq --argjson ob "$outbound" --arg tag "$tag" '
      .outbounds = ((.outbounds // []) | map(select(.tag != $tag)))
      | .outbounds = (
          ([.outbounds[] | select(.protocol == "freedom" or .tag == "direct")])
          + [$ob]
          + ([.outbounds[] | select(.protocol != "freedom" and .tag != "direct")])
        )
      | .routing //= {}
      | .routing.rules //= []
      | .routing.rules = (
          (.routing.rules | map(select(.name != "stealthsurf-default" and .outboundTag != $tag)))
          + [{
              "type": "field",
              "name": "stealthsurf-default",
              "outboundTag": $tag,
              "network": "tcp,udp",
              "enabled": true
            }]
        )
    ' "$XRAY_CONFIG_FILE" >"$XRAY_CONFIG_FILE.tmp" && mv "$XRAY_CONFIG_FILE.tmp" "$XRAY_CONFIG_FILE"
    ln -sf "$XRAY_CONFIG_FILE" "$ADDON_WEB_DIR/xray-config.json" 2>/dev/null || true
    load_xrayui_config
    # Catch-all stealthsurf-default needs full tunnel: redirect mode only matches PROXY ipsets
    if jq -e '.routing.rules[]? | select(.name == "stealthsurf-default")' "$XRAY_CONFIG_FILE" >/dev/null 2>&1; then
        if [ -z "${ipsec:-}" ] || [ "$ipsec" = "redirect" ]; then
            update_xrayui_config "ipsec" "off"
            ipsec="off"
        fi
    elif [ -z "${ipsec:-}" ]; then
        update_xrayui_config "ipsec" "off"
        ipsec="off"
    fi
    if [ "${check_connection:-}" != "true" ]; then
        update_xrayui_config "check_connection" "true"
        check_connection="true"
    fi
    log_ok "Imported StealthSurf config $config_id as outbound $tag ($title) [default route]"
}

ss_api_import_finalize() {
    # After imports: rebuild observatory selectors and restart so status badges appear
    load_xrayui_config
    update_xrayui_config "check_connection" "true"
    check_connection="true"
    if [ -z "${ipsec:-}" ]; then
        update_xrayui_config "ipsec" "off"
        ipsec="off"
    fi
    api_apply_configuration 2>/dev/null || true
    if [ -n "$(get_xray_daemon_pid 2>/dev/null || true)" ]; then
        log_info "Restarting Xray so new outbounds are probed for connection status..."
        restart || log_warn "Restart after import finished with warnings"
    fi
    initial_response 2>/dev/null || true
}

ss_api_import_enabled_batch() {
    # Import a list of config ids from payload {ids:[...]}
    local payload ids id ok=0
    payload=$(reconstruct_payload) || payload="{}"
    ids=$(printf '%s' "$payload" | jq -r '.ids // [] | .[]' 2>/dev/null)
    [ -n "$ids" ] || {
        log_error "No ids in payload"
        return 1
    }
    for id in $ids; do
        if ss_api_import_config_to_xray "$id"; then
            ok=$((ok + 1))
        fi
    done
    if [ "$ok" -gt 0 ]; then
        ss_api_import_finalize
        log_ok "Imported $ok configs into Xray (status probes enabled)"
        return 0
    fi
    log_error "No configs imported"
    return 1
}

ss_api_handle_setkey() {
    local payload key label
    payload=$(reconstruct_payload) || payload="{}"
    key=$(printf '%s' "$payload" | jq -r '.api_key // .key // empty')
    label=$(printf '%s' "$payload" | jq -r '.label // "primary"')
    ss_api_set_primary_key "$key" "$label"
}

ss_api_handle_addkey() {
    local payload key label
    payload=$(reconstruct_payload) || payload="{}"
    key=$(printf '%s' "$payload" | jq -r '.api_key // .key // empty')
    label=$(printf '%s' "$payload" | jq -r '.label // empty')
    ss_api_add_key "$key" "$label"
}

ss_api_handle_removekey() {
    local payload key
    payload=$(reconstruct_payload) || payload="{}"
    key=$(printf '%s' "$payload" | jq -r '.api_key // .key // empty')
    [ -n "$key" ] || return 1
    ss_api_keys_store_remove "$key"
    log_ok "API key removed"
}

ss_api_public_keys_view() {
    # Safe view for UI (no full keys)
    ss_api_ensure_caches
    jq '[.[] | {label:(.label // ""), key_fp:(.key|split("_")[1] // ""), key_tail:(.key[-8:]), added_at:(.added_at // 0)}]' "$SS_CACHE_KEYS" >"$ADDON_WEB_DIR/api_keys_safe.json" 2>/dev/null || echo '[]' >"$ADDON_WEB_DIR/api_keys_safe.json"
    # Keep full keys file for router-side only; UI should prefer safe + balances
    ln -sf "$SS_CACHE_KEYS" "$ADDON_WEB_DIR/api_keys.json" 2>/dev/null || true
}
