#!/bin/sh
# shellcheck disable=SC2034
# StealthSurf API ops: paid/cloud sync, PATCH settings, stats, traffic, autofit, billing.

ss_api_sync_paid_options() {
    local resp
    ss_api_ensure_caches
    ss_require_key || return 1
    resp=$(ss_api GET /paid-options 2>/dev/null) || resp='{"data":[]}'
    printf '%s' "$resp" | jq '.data // []' >"$SS_CACHE_PAID"
    ln -sf "$SS_CACHE_PAID" "$ADDON_WEB_DIR/ss_paid_options.json" 2>/dev/null || true
    log_ok "Synced paid options ($(jq 'length' "$SS_CACHE_PAID"))"
}

ss_api_flatten_paid_configs() {
    # Build flat catalog rows from cached paid-options (+ white_internet links).
    local entry option_id instance_id flat wi_json
    ss_api_ensure_caches
    echo '[]' >"$ADDON_TMP_DIR/paid.flat.$$"
    [ -f "$SS_CACHE_PAID" ] || {
        echo '[]'
        return 0
    }
    jq -c '.[]?' "$SS_CACHE_PAID" 2>/dev/null | while read -r entry; do
        [ -n "$entry" ] || continue
        instance_id=$(printf '%s' "$entry" | jq -r '.id // empty')
        option_id=$(printf '%s' "$entry" | jq -r '.option_id // empty')
        printf '%s' "$entry" | jq -c --argjson oid "${option_id:-0}" --argjson iid "${instance_id:-0}" '
          (.configs // []) | map(select(. != null and ((.connection_url // "") != "" or .xray_config != null))) |
          map(. + {
            _ss_source: "paid_option",
            _ss_parent_id: $oid,
            _ss_instance_id: $iid,
            _ss_tag: ("ss-po-" + (.id | tostring)),
            _ss_catalog_key: ("paid:" + ($oid|tostring) + ":" + (.id|tostring)),
            title: (.title // .custom_title // .original_title // ("paid-" + (.id|tostring)))
          })
        ' >"$ADDON_TMP_DIR/paid.one.$$" 2>/dev/null || echo '[]' >"$ADDON_TMP_DIR/paid.one.$$"
        jq -s '.[0] + .[1]' "$ADDON_TMP_DIR/paid.flat.$$" "$ADDON_TMP_DIR/paid.one.$$" >"$ADDON_TMP_DIR/paid.flat.n.$$" \
            && mv "$ADDON_TMP_DIR/paid.flat.n.$$" "$ADDON_TMP_DIR/paid.flat.$$"
        if [ -n "$option_id" ]; then
            wi_json=$(ss_api GET "/paid-options/${option_id}/configs" 2>/dev/null) || wi_json=""
            if [ -n "$wi_json" ]; then
                printf '%s' "$wi_json" | jq -c --argjson oid "$option_id" --argjson iid "${instance_id:-0}" '
                  (.data // []) | map(select(. != null and ((.connection_url // "") != ""))) |
                  map(. + {
                    id: (.id // .index // 0),
                    _ss_source: "paid_option",
                    _ss_parent_id: $oid,
                    _ss_instance_id: $iid,
                    _ss_tag: ("ss-po-wi-" + ($oid|tostring) + "-" + ((.index // .id // 0)|tostring)),
                    _ss_catalog_key: ("paid-wi:" + ($oid|tostring) + ":" + ((.index // .id // 0)|tostring)),
                    title: (.custom_title // .original_title // ("white-" + ((.index // 0)|tostring))),
                    protocol: (.protocol // "vless"),
                    is_online: (.is_online // true)
                  })
                ' >"$ADDON_TMP_DIR/paid.wi.one.$$" 2>/dev/null || echo '[]' >"$ADDON_TMP_DIR/paid.wi.one.$$"
                jq -s '.[0] + .[1]' "$ADDON_TMP_DIR/paid.flat.$$" "$ADDON_TMP_DIR/paid.wi.one.$$" >"$ADDON_TMP_DIR/paid.flat.n.$$" \
                    && mv "$ADDON_TMP_DIR/paid.flat.n.$$" "$ADDON_TMP_DIR/paid.flat.$$"
            fi
        fi
    done
    cat "$ADDON_TMP_DIR/paid.flat.$$"
}

ss_api_sync_cloud_servers() {
    local resp server_id cfgs flat
    ss_api_ensure_caches
    ss_require_key || return 1
    resp=$(ss_api GET /cloud-servers 2>/dev/null) || resp='{"data":[]}'
    printf '%s' "$resp" | jq '.data // []' >"$SS_CACHE_CLOUD"
    ln -sf "$SS_CACHE_CLOUD" "$ADDON_WEB_DIR/ss_cloud_servers.json" 2>/dev/null || true
    echo '[]' >"$ADDON_TMP_DIR/cloud.flat.$$"
    jq -r '.[].id // empty' "$SS_CACHE_CLOUD" 2>/dev/null | while read -r server_id; do
        [ -n "$server_id" ] || continue
        cfgs=$(ss_api GET "/cloud-servers/${server_id}/configs" 2>/dev/null) || continue
        printf '%s' "$cfgs" | jq -c --argjson sid "$server_id" '
          (.data // []) | map(select(. != null)) |
          map(. + {
            _ss_source: "cloud",
            _ss_parent_id: $sid,
            _ss_tag: ("ss-cs-" + (.id | tostring)),
            _ss_catalog_key: ("cloud:" + ($sid|tostring) + ":" + (.id|tostring)),
            title: (.title // .name // ("cloud-" + (.id|tostring)))
          })
        ' >"$ADDON_TMP_DIR/cloud.one.$$" 2>/dev/null || echo '[]' >"$ADDON_TMP_DIR/cloud.one.$$"
        jq -s '.[0] + .[1]' "$ADDON_TMP_DIR/cloud.flat.$$" "$ADDON_TMP_DIR/cloud.one.$$" >"$ADDON_TMP_DIR/cloud.flat.n.$$" \
            && mv "$ADDON_TMP_DIR/cloud.flat.n.$$" "$ADDON_TMP_DIR/cloud.flat.$$"
    done
    cp "$ADDON_TMP_DIR/cloud.flat.$$" "$ADDON_SHARE_DIR/ss_cloud_flat.tmp" 2>/dev/null || echo '[]' >"$ADDON_SHARE_DIR/ss_cloud_flat.tmp"
    log_ok "Synced cloud servers ($(jq 'length' "$SS_CACHE_CLOUD"))"
}

ss_api_merge_extra_into_catalog() {
    # Merge regular configs with paid/cloud flat rows into SS_CACHE_CONFIGS (unique by _ss_tag).
    local paid_flat cloud_flat
    ss_api_ensure_caches
    paid_flat=$(ss_api_flatten_paid_configs 2>/dev/null || echo '[]')
    cloud_flat='[]'
    [ -f "$ADDON_SHARE_DIR/ss_cloud_flat.tmp" ] && cloud_flat=$(cat "$ADDON_SHARE_DIR/ss_cloud_flat.tmp")
    printf '%s' "$paid_flat" >"$ADDON_TMP_DIR/paid.flat.final.$$"
    printf '%s' "$cloud_flat" >"$ADDON_TMP_DIR/cloud.flat.final.$$"
    # Keep only regular configs already in cache, then append extras.
    jq --slurpfile paid "$ADDON_TMP_DIR/paid.flat.final.$$" --slurpfile cloud "$ADDON_TMP_DIR/cloud.flat.final.$$" '
      (map(select((._ss_source // "config") == "config"))) as $base |
      ($base + ($paid[0] // []) + ($cloud[0] // [])) |
      unique_by(._ss_tag // ("ss-" + (.id|tostring)))
    ' "$SS_CACHE_CONFIGS" >"$SS_CACHE_CONFIGS.tmp" && mv -f "$SS_CACHE_CONFIGS.tmp" "$SS_CACHE_CONFIGS"
    ss_api_enrich_catalog_locations "$SS_CACHE_CONFIGS" || true
    ln -sf "$SS_CACHE_CONFIGS" "$ADDON_WEB_DIR/ss_configs.json" 2>/dev/null || true
    log_ok "Catalog merged: $(jq 'length' "$SS_CACHE_CONFIGS") entries"
}

ss_api_fetch_tariffs() {
    local configs_t paid_t
    ss_api_ensure_caches
    ss_require_key || return 1
    configs_t=$(ss_api GET /configs/tariffs 2>/dev/null) || configs_t='{"data":[]}'
    paid_t=$(ss_api GET /paid-options/tariffs 2>/dev/null) || paid_t='{"data":[]}'
    jq -nc --argjson ts "$(date +%s)" \
        --argjson configs "$(printf '%s' "$configs_t" | jq '.data // []')" \
        --argjson paid "$(printf '%s' "$paid_t" | jq '.data // []')" \
        '{fetched_at:$ts, configs:$configs, paid_options:$paid}' >"$SS_CACHE_TARIFFS"
    ln -sf "$SS_CACHE_TARIFFS" "$ADDON_WEB_DIR/ss_tariffs.json" 2>/dev/null || true
    log_ok "Synced tariffs"
}

ss_api_available_servers() {
    local location_id="$1"
    local protocol="$2"
    local resp
    ss_api_ensure_caches
    ss_require_key || return 1
    [ -n "$location_id" ] && [ -n "$protocol" ] || {
        log_error "usage: available-servers <location_id> <protocol>"
        return 1
    }
    resp=$(ss_api GET "/configs/available-servers?location_id=${location_id}&protocol=${protocol}") || return 1
    printf '%s' "$resp" | jq '.data // []' >"$SS_CACHE_AVAILABLE_SERVERS"
    ln -sf "$SS_CACHE_AVAILABLE_SERVERS" "$ADDON_WEB_DIR/ss_available_servers.json" 2>/dev/null || true
    cat "$SS_CACHE_AVAILABLE_SERVERS"
}

ss_api_handle_available_servers() {
    local payload location_id protocol
    payload=$(reconstruct_payload) || payload="{}"
    location_id=$(printf '%s' "$payload" | jq -r '.location_id // empty')
    protocol=$(printf '%s' "$payload" | jq -r '.protocol // empty')
    ss_api_available_servers "$location_id" "$protocol"
}

ss_api_server_stats() {
    local config_id="$1"
    local source="${2:-config}"
    local parent_id="$3"
    local resp
    ss_api_ensure_caches
    ss_require_key || return 1
    [ -n "$config_id" ] || return 1
    case "$source" in
    paid_option)
        [ -n "$parent_id" ] || return 1
        resp=$(ss_api GET "/paid-options/${parent_id}/configs/${config_id}/stats") || return 1
        ;;
    cloud)
        [ -n "$parent_id" ] || return 1
        resp=$(ss_api GET "/cloud-servers/${parent_id}/serverStats") || return 1
        ;;
    *)
        resp=$(ss_api GET "/configs/${config_id}/serverStats") || return 1
        ;;
    esac
    printf '%s' "$resp" | jq --argjson ts "$(date +%s)" --arg id "$config_id" \
        '{fetched_at:$ts, config_id:$id, data:(.data // null)}' >"$SS_CACHE_SERVER_STATS"
    ln -sf "$SS_CACHE_SERVER_STATS" "$ADDON_WEB_DIR/ss_server_stats.json" 2>/dev/null || true
    cat "$SS_CACHE_SERVER_STATS"
}

ss_api_handle_server_stats() {
    local payload id source parent
    payload=$(reconstruct_payload) || payload="{}"
    id=$(printf '%s' "$payload" | jq -r '.id // .config_id // empty')
    source=$(printf '%s' "$payload" | jq -r '.source // "config"')
    parent=$(printf '%s' "$payload" | jq -r '.parent_id // empty')
    ss_api_server_stats "$id" "$source" "$parent"
}

ss_api_fetch_traffic() {
    local scope_type="${1:-account}"
    local scope_id="$2"
    local group_by="${3:-day}"
    local days="${4:-30}"
    local path resp now from
    ss_api_ensure_caches
    ss_require_key || return 1
    now=$(date +%s)
    from=$((now - days * 86400))
    [ "$from" -lt 0 ] && from=0
    path="/traffic?from=${from}&to=${now}&group_by=${group_by}&scope_type=${scope_type}"
    if [ "$scope_type" != "account" ] && [ -n "$scope_id" ]; then
        path="${path}&scope_id=${scope_id}"
    fi
    resp=$(ss_api GET "$path") || return 1
    printf '%s' "$resp" | jq --argjson ts "$now" --arg st "$scope_type" --argjson sid "${scope_id:-null}" \
        '{fetched_at:$ts, scope_type:$st, scope_id:$sid, data:(.data // null)}' >"$SS_CACHE_TRAFFIC"
    ln -sf "$SS_CACHE_TRAFFIC" "$ADDON_WEB_DIR/ss_traffic.json" 2>/dev/null || true
    cat "$SS_CACHE_TRAFFIC"
}

ss_api_handle_traffic() {
    local payload scope_type scope_id group_by
    payload=$(reconstruct_payload) || payload="{}"
    scope_type=$(printf '%s' "$payload" | jq -r '.scope_type // "account"')
    scope_id=$(printf '%s' "$payload" | jq -r '.scope_id // empty')
    group_by=$(printf '%s' "$payload" | jq -r '.group_by // "day"')
    ss_api_fetch_traffic "$scope_type" "$scope_id" "$group_by"
}

ss_api_update_settings() {
    # PATCH settings for a catalog entry, then sync+refresh imported outbound if present.
    local config_id="$1"
    local body="$2"
    local source="${3:-config}"
    local parent_id="$4"
    local resp path
    ss_api_ensure_caches
    ss_require_key || return 1
    [ -n "$config_id" ] && [ -n "$body" ] || {
        log_error "update-settings requires config_id and JSON body"
        return 1
    }
    case "$source" in
    paid_option)
        [ -n "$parent_id" ] || {
            log_error "paid_option settings need parent_id (option_id)"
            return 1
        }
        path="/paid-options/${parent_id}/configs/${config_id}/settings"
        ;;
    cloud)
        [ -n "$parent_id" ] || {
            log_error "cloud settings need parent_id (server_id)"
            return 1
        }
        path="/cloud-servers/${parent_id}/configs/${config_id}/protocol"
        ;;
    *)
        path="/configs/${config_id}/settings"
        ;;
    esac
    resp=$(ss_api PATCH "$path" "$body") || return 1
    log_ok "Updated settings for $source:$config_id"
    # Refresh catalog connection fields and rebuild imported outbound if any.
    ss_api_sync_locations >/dev/null || true
    ss_api_sync_configs >/dev/null || true
    if [ "$source" != "config" ]; then
        ss_api_sync_paid_options >/dev/null || true
        ss_api_sync_cloud_servers >/dev/null || true
        ss_api_merge_extra_into_catalog >/dev/null || true
    else
        ss_api_merge_extra_into_catalog >/dev/null || true
    fi
    if ss_api_refresh_outbound_from_catalog "$config_id" 2>/dev/null \
        || ss_api_refresh_outbound_from_catalog "ss-$config_id" 2>/dev/null \
        || ss_api_refresh_outbound_from_catalog "ss-po-$config_id" 2>/dev/null \
        || ss_api_refresh_outbound_from_catalog "ss-cs-$config_id" 2>/dev/null; then
        printf '%s\n' "$(ss_api_connection_fingerprint)" >"$SS_IMPORTED_FP_FILE" 2>/dev/null || true
        ss_api_stamp_outbounds_from_catalog || true
        ss_api_import_finalize
    fi
    printf '%s' "$resp"
}

ss_api_handle_update_settings() {
    local payload id body source parent
    payload=$(reconstruct_payload) || payload="{}"
    id=$(printf '%s' "$payload" | jq -r '.id // .config_id // empty')
    source=$(printf '%s' "$payload" | jq -r '.source // "config"')
    parent=$(printf '%s' "$payload" | jq -r '.parent_id // empty')
    body=$(printf '%s' "$payload" | jq -c 'del(.id, .config_id, .source, .parent_id)')
    ss_api_update_settings "$id" "$body" "$source" "$parent"
}

ss_api_set_auto_renewal() {
    local config_id="$1"
    local enabled="$2"
    local days="$3"
    local body
    ss_require_key || return 1
    [ -n "$config_id" ] || return 1
    if [ "$enabled" = "true" ] || [ "$enabled" = "1" ]; then
        body=$(jq -nc --argjson days "${days:-30}" '{enabled:true, days:$days}')
    else
        body='{"enabled":false}'
    fi
    ss_api PATCH "/configs/${config_id}/auto-renewal" "$body" || return 1
    ss_api_sync_configs >/dev/null || true
    ss_api_merge_extra_into_catalog >/dev/null || true
    log_ok "Auto-renewal updated for $config_id"
}

ss_api_handle_auto_renewal() {
    local payload id enabled days
    payload=$(reconstruct_payload) || payload="{}"
    id=$(printf '%s' "$payload" | jq -r '.id // .config_id // empty')
    enabled=$(printf '%s' "$payload" | jq -r '.enabled // false')
    days=$(printf '%s' "$payload" | jq -r '.days // 30')
    ss_api_set_auto_renewal "$id" "$enabled" "$days"
}

ss_api_renew_config() {
    local config_id="$1"
    local tariff_id="$2"
    local payment_method_id="$3"
    local body
    ss_require_key || return 1
    [ -n "$config_id" ] || return 1
    body=$(jq -nc --argjson tariff "${tariff_id:-null}" --argjson pm "${payment_method_id:-null}" '
      {}
      + (if $tariff != null then {tariff_id:$tariff} else {} end)
      + (if $pm != null then {payment_method_id:$pm} else {} end)
    ')
    ss_api POST "/configs/renewal/${config_id}" "$body" || return 1
    ss_api_sync_configs >/dev/null || true
    ss_api_merge_extra_into_catalog >/dev/null || true
    log_ok "Renewal requested for $config_id"
}

ss_api_handle_renew() {
    local payload id tariff pm
    payload=$(reconstruct_payload) || payload="{}"
    id=$(printf '%s' "$payload" | jq -r '.id // .config_id // empty')
    tariff=$(printf '%s' "$payload" | jq -r '.tariff_id // empty')
    pm=$(printf '%s' "$payload" | jq -r '.payment_method_id // empty')
    ss_api_renew_config "$id" "$tariff" "$pm"
}

ss_api_topup_balance() {
    local amount="$1"
    local payment_method_id="$2"
    local body resp
    ss_api_ensure_caches
    ss_require_key || return 1
    [ -n "$amount" ] || return 1
    body=$(jq -nc --argjson amount "$amount" --argjson pm "${payment_method_id:-null}" '
      {amount:$amount} + (if $pm != null then {payment_method_id:$pm} else {} end)
    ')
    resp=$(ss_api POST /profile/balance/topup "$body") || return 1
    printf '%s' "$resp" | jq '.' >"$ADDON_WEB_DIR/ss_topup.json" 2>/dev/null || true
    ss_api_fetch_balances 1 >/dev/null || true
    printf '%s' "$resp"
}

ss_api_handle_topup() {
    local payload amount pm
    payload=$(reconstruct_payload) || payload="{}"
    amount=$(printf '%s' "$payload" | jq -r '.amount // empty')
    pm=$(printf '%s' "$payload" | jq -r '.payment_method_id // empty')
    ss_api_topup_balance "$amount" "$pm"
}

ss_api_calculate_topup() {
    local amount="$1"
    local resp
    ss_require_key || return 1
    resp=$(ss_api GET "/profile/balance/calculate?amount=${amount}") || return 1
    printf '%s' "$resp" | jq '.data // .' >"$ADDON_WEB_DIR/ss_topup_calc.json" 2>/dev/null || true
    printf '%s' "$resp"
}

ss_api_handle_topup_calc() {
    local payload amount
    payload=$(reconstruct_payload) || payload="{}"
    amount=$(printf '%s' "$payload" | jq -r '.amount // 100')
    ss_api_calculate_topup "$amount"
}

ss_api_probe_tag_alive() {
    # Return 0 if Observatory reports alive=true for tag.
    local tag="$1"
    local obs
    [ -n "$tag" ] || return 1
    api_get_connection_status >/dev/null 2>&1 || true
    [ -f "$XRAYUI_CONNECTION_STATUS_FILE" ] || return 1
    obs=$(jq -r --arg t "$tag" '
      .observatory // {} |
      to_entries[]? |
      select((.value.outbound_tag // .key) == $t) |
      .value.alive // false
    ' "$XRAYUI_CONNECTION_STATUS_FILE" 2>/dev/null | head -n1)
    [ "$obs" = "true" ]
}

ss_api_wait_probe_alive() {
    local tag="$1"
    local tries="${2:-8}"
    local i=0
    while [ "$i" -lt "$tries" ]; do
        if ss_api_probe_tag_alive "$tag"; then
            return 0
        fi
        i=$((i + 1))
        sleep 2
    done
    return 1
}

ss_api_autofit_config() {
    # Try server / protocol / stealth flags until router Observatory is green.
    local config_id="$1"
    local cfg location_id protocol tag servers server_id candidate body tried=0
    local protocols proto flag_json
    ss_api_ensure_caches
    ss_require_key || return 1
    [ -n "$config_id" ] || return 1
    cfg=$(ss_api_catalog_lookup "$config_id")
    [ -n "$cfg" ] || {
        log_error "Config $config_id not in catalog — sync first"
        return 1
    }
    location_id=$(printf '%s' "$cfg" | jq -r '.location_id // empty')
    protocol=$(printf '%s' "$cfg" | jq -r '.protocol // "vless"')
    tag=$(printf '%s' "$cfg" | jq -r '._ss_tag // ("ss-" + (.id|tostring))')
    config_id=$(printf '%s' "$cfg" | jq -r '.id')

    jq -nc --argjson ts "$(date +%s)" --arg id "$config_id" --arg tag "$tag" \
        '{started_at:$ts, config_id:$id, tag:$tag, status:"running", attempts:[], winner:null}' >"$SS_CACHE_AUTOFIT"
    ln -sf "$SS_CACHE_AUTOFIT" "$ADDON_WEB_DIR/ss_autofit.json" 2>/dev/null || true

    # Ensure imported so we can probe.
    if ! jq -e --arg tag "$tag" '[.outbounds[]? | select(.tag == $tag)] | length > 0' "$XRAY_CONFIG_FILE" >/dev/null 2>&1; then
        ss_api_import_config_to_xray "$config_id" || true
        ss_api_import_finalize
    fi

    # Candidate matrix: alternate servers (same protocol), then protocol swaps, then stealth flags.
    servers=$(ss_api_available_servers "$location_id" "$protocol" 2>/dev/null || echo '[]')
    for server_id in $(printf '%s' "$servers" | jq -r '.[].id // empty' 2>/dev/null); do
        [ -n "$server_id" ] || continue
        [ "$tried" -lt 8 ] || break
        body=$(jq -nc --argjson loc "$location_id" --arg proto "$protocol" --argjson sid "$server_id" \
            '{location_id:$loc, protocol:$proto, server_id:$sid}')
        log_info "Autofit: try server=$server_id protocol=$protocol"
        tried=$((tried + 1))
        if ss_api_update_settings "$config_id" "$body" "config" >/dev/null 2>&1; then
            sleep 1
            if ss_api_wait_probe_alive "$tag" 6; then
                jq --argjson ts "$(date +%s)" --argjson body "$body" \
                    '.status="ok" | .finished_at=$ts | .winner=$body | .attempts += [$body]' "$SS_CACHE_AUTOFIT" >"$SS_CACHE_AUTOFIT.tmp" \
                    && mv "$SS_CACHE_AUTOFIT.tmp" "$SS_CACHE_AUTOFIT"
                log_ok "Autofit succeeded with server $server_id"
                return 0
            fi
            jq --argjson body "$body" '.attempts += [$body]' "$SS_CACHE_AUTOFIT" >"$SS_CACHE_AUTOFIT.tmp" && mv "$SS_CACHE_AUTOFIT.tmp" "$SS_CACHE_AUTOFIT"
        fi
        sleep 1
    done

    protocols="vless trojan hysteria2 shadowsocks-2022 vless-2410 trojan-2901"
    for proto in $protocols; do
        [ "$proto" = "$protocol" ] && continue
        body=$(jq -nc --argjson loc "$location_id" --arg proto "$proto" '{location_id:$loc, protocol:$proto}')
        log_info "Autofit: try protocol=$proto"
        if ss_api_update_settings "$config_id" "$body" "config" >/dev/null 2>&1; then
            sleep 1
            if ss_api_wait_probe_alive "$tag" 6; then
                jq --argjson ts "$(date +%s)" --argjson body "$body" \
                    '.status="ok" | .finished_at=$ts | .winner=$body | .attempts += [$body]' "$SS_CACHE_AUTOFIT" >"$SS_CACHE_AUTOFIT.tmp" \
                    && mv "$SS_CACHE_AUTOFIT.tmp" "$SS_CACHE_AUTOFIT"
                log_ok "Autofit succeeded with protocol $proto"
                return 0
            fi
            jq --argjson body "$body" '.attempts += [$body]' "$SS_CACHE_AUTOFIT" >"$SS_CACHE_AUTOFIT.tmp" && mv "$SS_CACHE_AUTOFIT.tmp" "$SS_CACHE_AUTOFIT"
        fi
        sleep 1
    done

    # Stealth flag variants on original / last protocol.
    protocol=$(jq -r --arg id "$config_id" 'map(select((.id|tostring)==$id))|first|.protocol // "vless"' "$SS_CACHE_CONFIGS")
    for flag_json in \
        '{"disable_reality":true}' \
        '{"change_sni":true}' \
        '{"use_xhttp":true}' \
        '{"use_grpc":true}' \
        '{"disable_reality":true,"change_sni":true}' \
        '{"use_extended_settings":true,"disable_reality":true}'; do
        body=$(jq -nc --argjson loc "$location_id" --arg proto "$protocol" --argjson flags "$flag_json" \
            '{location_id:$loc, protocol:$proto} + $flags')
        log_info "Autofit: try flags $flag_json"
        if ss_api_update_settings "$config_id" "$body" "config" >/dev/null 2>&1; then
            sleep 1
            if ss_api_wait_probe_alive "$tag" 6; then
                jq --argjson ts "$(date +%s)" --argjson body "$body" \
                    '.status="ok" | .finished_at=$ts | .winner=$body | .attempts += [$body]' "$SS_CACHE_AUTOFIT" >"$SS_CACHE_AUTOFIT.tmp" \
                    && mv "$SS_CACHE_AUTOFIT.tmp" "$SS_CACHE_AUTOFIT"
                log_ok "Autofit succeeded with flags"
                return 0
            fi
            jq --argjson body "$body" '.attempts += [$body]' "$SS_CACHE_AUTOFIT" >"$SS_CACHE_AUTOFIT.tmp" && mv "$SS_CACHE_AUTOFIT.tmp" "$SS_CACHE_AUTOFIT"
        fi
        sleep 1
    done

    jq --argjson ts "$(date +%s)" '.status="failed" | .finished_at=$ts' "$SS_CACHE_AUTOFIT" >"$SS_CACHE_AUTOFIT.tmp" \
        && mv "$SS_CACHE_AUTOFIT.tmp" "$SS_CACHE_AUTOFIT"
    log_warn "Autofit could not find a green combination for $config_id"
    return 1
}

ss_api_handle_autofit() {
    local payload id
    payload=$(reconstruct_payload) || payload="{}"
    id=$(printf '%s' "$payload" | jq -r '.id // .config_id // empty')
    ss_api_autofit_config "$id"
}
