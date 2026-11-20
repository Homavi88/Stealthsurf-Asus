#!/bin/sh
# shellcheck disable=SC2034  # codacy:Unused variables

load_xrayui_config() {
    if [ -f "$XRAYUI_CONFIG_FILE" ]; then
        . "$XRAYUI_CONFIG_FILE"
    fi

    # Isolated profile tree — never fall back to stock XrayUI /opt/etc/xray/config.json
    mkdir -p "$XRAY_CONFIG_DIR" 2>/dev/null
    XRAY_CONFIG_FILE="$XRAY_CONFIG_DIR/${profile:-$DEFAULT_XRAY_PROFILE_NAME}"

}

update_xrayui_config() {
    local key="$1"
    local value="$2"
    [ -f "$XRAYUI_CONFIG_FILE" ] || touch "$XRAYUI_CONFIG_FILE"
    # Escape for shell sourcing (the config file is sourced with .)
    local sh_safe
    sh_safe=$(printf '%s' "$value" | sed 's/[\\\"$`]/\\&/g')
    if grep -qE "^${key}=" "$XRAYUI_CONFIG_FILE"; then
        # Additionally escape for sed replacement string
        local sed_safe
        sed_safe=$(printf '%s' "$sh_safe" | sed 's/[|&\\]/\\&/g')
        sed "s|^${key}=.*|${key}=\"${sed_safe}\"|" "$XRAYUI_CONFIG_FILE" >"/tmp/stealthsurf_config.$$" && mv "/tmp/stealthsurf_config.$$" "$XRAYUI_CONFIG_FILE"
    else
        printf '%s="%s"\n' "$key" "$sh_safe" >>"$XRAYUI_CONFIG_FILE"
    fi
}

# True when file is non-empty JSON object (rejects NUL-padded / truncated flash writes).
xray_config_is_valid() {
    local f="$1"
    [ -n "$f" ] && [ -f "$f" ] && [ -s "$f" ] || return 1
    # Leading NUL → classic "invalid character '\x00'" from xray -test
    case "$(dd if="$f" bs=1 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')" in
    00) return 1 ;;
    esac
    jq -e 'type == "object"' "$f" >/dev/null 2>&1
}

# Quarantine corrupt profile; restore newest valid .bak or leave missing for scaffold.
repair_xray_config_if_corrupt() {
    load_xrayui_config
    local f="$XRAY_CONFIG_FILE"
    if xray_config_is_valid "$f"; then
        return 0
    fi

    local base bak restored=0
    base=$(basename "$f")
    log_error "Xray config missing or corrupt ($f) — recovering"

    if [ -f "$f" ]; then
        local bad="${f}.corrupt.$(date +%Y%m%d-%H%M%S)"
        mv -f "$f" "$bad" 2>/dev/null || rm -f "$f"
        log_warn "Quarantined bad config as $bad"
    fi

    # Prefer temp.bak from last apply, then newest rolling .bak
    set -- "$XRAY_CONFIG_DIR/${base}-temp.bak"
    # shellcheck disable=SC2046
    set -- "$@" $(ls -1t "$XRAY_CONFIG_DIR/${base}".*.bak 2>/dev/null)
    for bak in "$@"; do
        [ -n "$bak" ] && [ -f "$bak" ] || continue
        if xray_config_is_valid "$bak"; then
            if cp -f "$bak" "$f"; then
                log_ok "Restored Xray config from $bak"
                restored=1
                break
            fi
        fi
    done

    [ "$restored" = "1" ] && return 0
    log_warn "No valid backup for $base — a default scaffold will be created"
    return 1
}

# XrayUI-shaped scaffold: dokodemo all-in + direct (first) + block.
# Used for fresh configs and to repair empty/corrupt profiles so Start/Stop control real traffic.
ensure_xray_scaffold() {
    load_xrayui_config
    mkdir -p "$XRAY_CONFIG_DIR" "$ADDON_LOGS_DIR" 2>/dev/null || true

    repair_xray_config_if_corrupt || true

    if [ ! -f "$XRAY_CONFIG_FILE" ] || ! xray_config_is_valid "$XRAY_CONFIG_FILE"; then
        cat >"$XRAY_CONFIG_FILE" <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "$ADDON_LOGS_DIR/xray_access.log",
    "error": "$ADDON_LOGS_DIR/xray_error.log"
  },
  "inbounds": [],
  "outbounds": [],
  "routing": { "domainStrategy": "AsIs", "rules": [] },
  "dns": { "servers": ["localhost"] }
}
EOF
        log_ok "Wrote default Xray scaffold to $XRAY_CONFIG_FILE"
    fi

    # Xray ≥26.9 dropped top-level "legacy reverse" (bridges/portals). SurfGate is a
    # client transparent proxy — strip it so start/test no longer fail with:
    #   "legacy reverse" has been removed and migrated to "VLESS Reverse Proxy"
    jq '
      del(.reverse)
      | .log = (.log // {})
      | .log.loglevel = (.log.loglevel // "warning")
      | .inbounds = (.inbounds // [])
      | .outbounds = (.outbounds // [])
      | .routing = (.routing // {})
      | .routing.domainStrategy = (.routing.domainStrategy // "AsIs")
      | .routing.rules = (.routing.rules // [])
      | .dns = (.dns // {})
      | .dns.servers = (.dns.servers // ["localhost"])
      | if ([.inbounds[] | select(.tag == "all-in")] | length) > 0 then .
        else .inbounds += [{
          "protocol": "dokodemo-door",
          "listen": "127.0.0.1",
          "port": 5699,
          "tag": "all-in",
          "settings": { "address": "", "network": "tcp,udp", "followRedirect": true },
          "streamSettings": {
            "sockopt": {
              "tproxy": "tproxy",
              "tcpKeepAliveIdle": 300,
              "tcpKeepAliveInterval": 30
            }
          },
          "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
        }] end
      # Vanish clients (phone Wi‑Fi drop) leave TCP open for hours without keepalive → RAM bleed.
      # Apply defaults on existing all-in / tproxy inbounds that never set keepalive.
      | .inbounds |= map(
          if ((.streamSettings.sockopt.tproxy // "") == "tproxy")
             or (.tag == "all-in") then
            .streamSettings //= {}
            | .streamSettings.sockopt //= {}
            | .streamSettings.sockopt.tproxy = (.streamSettings.sockopt.tproxy // "tproxy")
            | .streamSettings.sockopt.tcpKeepAliveIdle =
                (.streamSettings.sockopt.tcpKeepAliveIdle // 300)
            | .streamSettings.sockopt.tcpKeepAliveInterval =
                (.streamSettings.sockopt.tcpKeepAliveInterval // 30)
          else . end
        )
      | if ([.outbounds[] | select(.tag == "direct" or .protocol == "freedom")] | length) > 0 then .
        else .outbounds = [{ "protocol": "freedom", "tag": "direct", "settings": {} }] + .outbounds end
      | if ([.outbounds[] | select(.tag == "block" or .protocol == "blackhole")] | length) > 0 then .
        else .outbounds += [{ "protocol": "blackhole", "tag": "block", "settings": {} }] end
    ' "$XRAY_CONFIG_FILE" >"$XRAY_CONFIG_FILE.tmp" && mv -f "$XRAY_CONFIG_FILE.tmp" "$XRAY_CONFIG_FILE"

    # Fresh installs: send all LAN traffic into Xray (ipsec=off).
    # Catch-all routing rules need this — ipsec=redirect only proxies PROXY-ipset destinations.
    # Respect an explicit user value if already set.
    if [ -z "${ipsec:-}" ]; then
        update_xrayui_config "ipsec" "off"
        ipsec="off"
    fi
    # Status probes for Outbounds list (🟢/🔴) — enable when unset
    if [ -z "${check_connection:-}" ]; then
        update_xrayui_config "check_connection" "true"
        check_connection="true"
    fi

    # Overlay API titles / is_online onto already imported ss-<id> outbounds.
    if type ss_api_stamp_outbounds_from_catalog >/dev/null 2>&1; then
        ss_api_stamp_outbounds_from_catalog || true
    fi

    # Repair DNS leak wiring if it is already enabled (do not re-enable a user disable).
    if type ss_api_ensure_dns_leak >/dev/null 2>&1 &&
        jq -e '(.outbounds // []) | any(.tag == "sys:dns-out")' "$XRAY_CONFIG_FILE" >/dev/null 2>&1; then
        def_tag=$(jq -r '.routing.rules[]? | select(.name=="stealthsurf-default") | .outboundTag // empty' "$XRAY_CONFIG_FILE" 2>/dev/null | head -1)
        if [ -n "$def_tag" ]; then
            ss_api_ensure_dns_leak "$def_tag" || true
        fi
    fi
}

generate_xray_config() {
    load_xrayui_config
    if xray_config_is_valid "$XRAY_CONFIG_FILE"; then
        log_warn "Base configuration file already exists."
        ensure_xray_scaffold
        return 0
    fi
    log_warn "Base configuration missing or corrupt. Creating/repairing default config..."
    ensure_xray_scaffold
    if xray_config_is_valid "$XRAY_CONFIG_FILE"; then
        log_ok "Default configuration created successfully (all-in + direct + block)."
    else
        log_error "Failed to create default configuration."
        exit 1
    fi
}
