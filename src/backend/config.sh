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

# XrayUI-shaped scaffold: dokodemo all-in + direct (first) + block.
# Used for fresh configs and to repair empty profiles so Start/Stop control real traffic.
ensure_xray_scaffold() {
    load_xrayui_config
    mkdir -p "$XRAY_CONFIG_DIR" "$ADDON_LOGS_DIR" 2>/dev/null || true
    if [ ! -f "$XRAY_CONFIG_FILE" ]; then
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
    fi

    jq '
      .log = (.log // {})
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
          "streamSettings": { "sockopt": { "tproxy": "tproxy" } },
          "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
        }] end
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
    if [ ! -f "$XRAY_CONFIG_FILE" ]; then
        log_warn "Base configuration file not found. Creating a default config..."
        ensure_xray_scaffold
        if [ -f "$XRAY_CONFIG_FILE" ]; then
            log_ok "Default configuration created successfully (all-in + direct + block)."
        else
            log_error "Failed to create default configuration."
            exit 1
        fi
    else
        log_warn "Base configuration file already exists."
        ensure_xray_scaffold
    fi
}
