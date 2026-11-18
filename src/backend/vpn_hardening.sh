#!/bin/sh
# shellcheck disable=SC2034
# Boot / WAN / kill-switch / LAN device mode / IPv6 / guest / preflight

FW_KILLSWITCH_CHAIN="${ADDON_TAG_UPPER}_KILLSWITCH"
PREFLIGHT_STATUS_FILE="${PREFLIGHT_STATUS_FILE:-$ADDON_SHARE_DIR/preflight_status.json}"

# ── 1. NTP ──────────────────────────────────────────────────────────────────
vpn_ntp_wait() {
    load_xrayui_config 2>/dev/null || true
    [ "${skipwait:-false}" = "true" ] && return 0
    if type ntp_ready >/dev/null 2>&1; then
        ntp_ready
        return $?
    fi
    return 0
}

# ── 2. WAN reconnect ────────────────────────────────────────────────────────
vpn_wan_reconnect() {
    load_xrayui_config
    log_info "WAN event — refreshing SurfGate transparent proxy…"

    if [ ! -f "$XRAY_DESIRED_STATE_FILE" ]; then
        log_info "WAN reconnect: VPN not desired — skip"
        return 0
    fi

    if ss_xrayui_running 2>/dev/null; then
        log_warn "WAN reconnect: stock XrayUI active — skip SurfGate restore"
        return 0
    fi

    local pid
    pid=$(get_xray_daemon_pid 2>/dev/null || true)
    if [ -z "$pid" ]; then
        log_warn "WAN reconnect: Xray down while desired — restarting"
        with_restart_lock start
        return $?
    fi

    # Process alive: rebuild firewall / routes (PPPoE ifname may have changed)
    if type configure_firewall >/dev/null 2>&1; then
        configure_firewall
    fi
    if [ "${kill_switch:-false}" = "true" ]; then
        vpn_kill_switch_apply
    fi
    log_ok "WAN reconnect: firewall refreshed"
    return 0
}

vpn_wan_hook_install() {
    # Asuswrt-Merlin: /jffs/scripts/wan-event  $1=unit $2=event (connected|disconnected|…)
    setup_script_file "/jffs/scripts/wan-event" \
        "[ \"\$2\" = \"connected\" ] && $ADDON_SCRIPT service_event wan reconnect & #ssurf"
    # Fallback for older scripts that only have wan-start
    setup_script_file "/jffs/scripts/wan-start" \
        "$ADDON_SCRIPT service_event wan reconnect & #ssurf"
}

# ── 3. Kill-switch ──────────────────────────────────────────────────────────
vpn_kill_switch_clear() {
    local IPT
    for IPT in iptables ip6tables; do
        command -v "$IPT" >/dev/null 2>&1 || continue
        $IPT -w -t filter -D FORWARD -j "$FW_KILLSWITCH_CHAIN" 2>/dev/null || true
        $IPT -w -t filter -F "$FW_KILLSWITCH_CHAIN" 2>/dev/null || true
        $IPT -w -t filter -X "$FW_KILLSWITCH_CHAIN" 2>/dev/null || true
    done
}

vpn_kill_switch_apply() {
    load_xrayui_config
    vpn_kill_switch_clear

    if [ "${kill_switch:-false}" != "true" ]; then
        return 0
    fi
    # Only while VPN is supposed to be up
    if [ ! -f "$XRAY_DESIRED_STATE_FILE" ]; then
        log_debug "Kill-switch: desired state clear — not arming"
        return 0
    fi

    local wan0 wan1 lan_if IPT
    wan0=$(nvram get wan0_ifname 2>/dev/null)
    wan1=$(nvram get wan1_ifname 2>/dev/null)
    lan_if=$(nvram get lan_ifname 2>/dev/null)

    log_info "Arming kill-switch (block LAN→WAN unless marked for SurfGate)…"

    for IPT in iptables ip6tables; do
        command -v "$IPT" >/dev/null 2>&1 || continue
        if [ "$IPT" = "ip6tables" ]; then
            case "${ipv6_mode:-proxy}" in
            ignore) continue ;;
            esac
            is_ipv6_enabled 2>/dev/null || continue
        fi
        $IPT -w -t filter -N "$FW_KILLSWITCH_CHAIN" 2>/dev/null || $IPT -w -t filter -F "$FW_KILLSWITCH_CHAIN"
        # Already established / related
        $IPT -w -t filter -A "$FW_KILLSWITCH_CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
        # Traffic already marked for TPROXY / our divert
        $IPT -w -t filter -A "$FW_KILLSWITCH_CHAIN" -m mark --mark "$tproxy_mark/$tproxy_mask" -j RETURN
        # Local / private destinations stay local
        if [ "$IPT" = "iptables" ]; then
            $IPT -w -t filter -A "$FW_KILLSWITCH_CHAIN" -d 10.0.0.0/8 -j RETURN
            $IPT -w -t filter -A "$FW_KILLSWITCH_CHAIN" -d 172.16.0.0/12 -j RETURN
            $IPT -w -t filter -A "$FW_KILLSWITCH_CHAIN" -d 192.168.0.0/16 -j RETURN
            $IPT -w -t filter -A "$FW_KILLSWITCH_CHAIN" -d 127.0.0.0/8 -j RETURN
            $IPT -w -t filter -A "$FW_KILLSWITCH_CHAIN" -d 169.254.0.0/16 -j RETURN
        else
            $IPT -w -t filter -A "$FW_KILLSWITCH_CHAIN" -d fc00::/7 -j RETURN
            $IPT -w -t filter -A "$FW_KILLSWITCH_CHAIN" -d fe80::/10 -j RETURN
            $IPT -w -t filter -A "$FW_KILLSWITCH_CHAIN" -d ::1/128 -j RETURN
        fi
        # Packets leaving via WAN without mark → DROP
        [ -n "$wan0" ] && $IPT -w -t filter -A "$FW_KILLSWITCH_CHAIN" -o "$wan0" -j DROP
        [ -n "$wan1" ] && [ "$wan1" != "$wan0" ] && $IPT -w -t filter -A "$FW_KILLSWITCH_CHAIN" -o "$wan1" -j DROP
        # Hook at top of FORWARD
        $IPT -w -t filter -I FORWARD 1 -j "$FW_KILLSWITCH_CHAIN" 2>/dev/null || \
            $IPT -w -t filter -A FORWARD -j "$FW_KILLSWITCH_CHAIN"
    done
    log_ok "Kill-switch armed"
}

# ── 4. LAN device mode → routing.policies ───────────────────────────────────
# all      = no MAC policies (default redirect everyone)
# selected = redirect only listed MACs
# exclude  = bypass listed MACs (everyone else VPN)
vpn_lan_policies_sync() {
    load_xrayui_config
    local mode="${lan_vpn_mode:-all}"
    local macs="${lan_vpn_macs:-}"
    local tmp

    [ -f "$XRAY_CONFIG_FILE" ] || return 0

    # Normalise MAC list: lower-case, comma-separated → JSON array
    macs=$(printf '%s' "$macs" | tr 'A-F' 'a-f' | tr ';\n ' ',,,' | sed 's/,,*/,/g; s/^,//; s/,$//')

    case "$mode" in
    selected | exclude)
        if [ -z "$macs" ]; then
            log_warn "lan_vpn_mode=$mode but lan_vpn_macs empty — falling back to all"
            mode="all"
        fi
        ;;
    *) mode="all" ;;
    esac

    tmp="${ADDON_TMP_DIR}/ssurf_policies.$$"
    mkdir -p "$ADDON_TMP_DIR" 2>/dev/null || true

    case "$mode" in
    all)
        jq '
          .routing = (.routing // {})
          | .routing.policies = (
              [(.routing.policies // [])[] | select((.name // "") | startswith("surfgate-lan-") | not)]
            )
        ' "$XRAY_CONFIG_FILE" >"$tmp" && mv -f "$tmp" "$XRAY_CONFIG_FILE"
        ;;
    selected)
        jq --arg macs "$macs" '
          ($macs | split(",") | map(select(length>0))) as $m
          | .routing = (.routing // {})
          | .routing.policies = (
              [(.routing.policies // [])[] | select((.name // "") | startswith("surfgate-lan-") | not)]
              + [{
                  name: "surfgate-lan-selected",
                  mode: "redirect",
                  enabled: true,
                  mac: $m,
                  tcp: "",
                  udp: ""
                }]
            )
        ' "$XRAY_CONFIG_FILE" >"$tmp" && mv -f "$tmp" "$XRAY_CONFIG_FILE"
        ;;
    exclude)
        jq --arg macs "$macs" '
          ($macs | split(",") | map(select(length>0))) as $m
          | .routing = (.routing // {})
          | .routing.policies = (
              [(.routing.policies // [])[] | select((.name // "") | startswith("surfgate-lan-") | not)]
              + [{
                  name: "surfgate-lan-exclude",
                  mode: "bypass",
                  enabled: true,
                  mac: $m,
                  tcp: "",
                  udp: ""
                }]
            )
        ' "$XRAY_CONFIG_FILE" >"$tmp" && mv -f "$tmp" "$XRAY_CONFIG_FILE"
        ;;
    esac
    rm -f "$tmp" 2>/dev/null
    log_info "LAN VPN mode applied: $mode"
}

# ── 5/7. IPv6 mode ──────────────────────────────────────────────────────────
# proxy = include v6 in transparent proxy (default)
# block = drop LAN IPv6 forward to WAN
# ignore = do not touch IPv6
vpn_ipv6_mode_active() {
    case "${ipv6_mode:-proxy}" in
    ignore) return 1 ;;
    *)
        # fall through to stock capability check
        [ -f /proc/net/if_inet6 ] || return 1
        [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)" = "0" ] || return 1
        ip6tables -w -L -n >/dev/null 2>&1 || return 1
        return 0
        ;;
    esac
}

vpn_ipv6_block_apply() {
    load_xrayui_config
    if [ "${ipv6_mode:-proxy}" != "block" ]; then
        return 0
    fi
    command -v ip6tables >/dev/null 2>&1 || return 0
    local wan0 wan1
    wan0=$(nvram get wan0_ifname 2>/dev/null)
    wan1=$(nvram get wan1_ifname 2>/dev/null)
    log_info "IPv6 mode=block — dropping LAN IPv6 toward WAN"
    ip6tables -w -t filter -N "${ADDON_TAG_UPPER}_V6BLOCK" 2>/dev/null || ip6tables -w -t filter -F "${ADDON_TAG_UPPER}_V6BLOCK"
    ip6tables -w -t filter -A "${ADDON_TAG_UPPER}_V6BLOCK" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
    ip6tables -w -t filter -A "${ADDON_TAG_UPPER}_V6BLOCK" -d fc00::/7 -j RETURN
    ip6tables -w -t filter -A "${ADDON_TAG_UPPER}_V6BLOCK" -d fe80::/10 -j RETURN
    [ -n "$wan0" ] && ip6tables -w -t filter -A "${ADDON_TAG_UPPER}_V6BLOCK" -o "$wan0" -j DROP
    [ -n "$wan1" ] && [ "$wan1" != "$wan0" ] && ip6tables -w -t filter -A "${ADDON_TAG_UPPER}_V6BLOCK" -o "$wan1" -j DROP
    ip6tables -w -t filter -I FORWARD 1 -j "${ADDON_TAG_UPPER}_V6BLOCK" 2>/dev/null || true
}

vpn_ipv6_block_clear() {
    command -v ip6tables >/dev/null 2>&1 || return 0
    ip6tables -w -t filter -D FORWARD -j "${ADDON_TAG_UPPER}_V6BLOCK" 2>/dev/null || true
    ip6tables -w -t filter -F "${ADDON_TAG_UPPER}_V6BLOCK" 2>/dev/null || true
    ip6tables -w -t filter -X "${ADDON_TAG_UPPER}_V6BLOCK" 2>/dev/null || true
}

# ── 8. Guest Wi-Fi ──────────────────────────────────────────────────────────
# follow = include guest nets (default)
# vpn    = force guest into VPN (same as follow for redirect-all; still include nets)
# direct = exclude guest bridge nets from transparent proxy source list
vpn_guest_ifaces() {
    local guest_ifs="" g n
    for n in 1 2 3; do
        g=$(nvram get "lan${n}_ifname" 2>/dev/null)
        [ -n "$g" ] && guest_ifs="$guest_ifs $g"
    done
    guest_ifs="$guest_ifs $(ip -4 route show scope link 2>/dev/null |
        awk -v lan="$(nvram get lan_ifname 2>/dev/null)" \
            '$3 ~ /^br[0-9]+$/ && $3 != lan && $1 ~ /^(10\.|172\.(1[6-9]|2[0-9]|3[0-1])|192\.168\.)/ {print $3}')"
    printf '%s\n' $guest_ifs | sed '/^$/d' | sort -u
}

vpn_guest_nets_v4() {
    local ifc
    for ifc in $(vpn_guest_ifaces); do
        ip -4 route show proto kernel dev "$ifc" 2>/dev/null | awk '{print $1}'
        ip -4 addr show dev "$ifc" 2>/dev/null | awk '/inet /{print $2}'
    done | sed '/^$/d' | sort -u
}

# Filter source_nets list: when guest_vpn_mode=direct, drop guest CIDRs
vpn_filter_source_nets() {
    local nets="$1"
    local mode="${guest_vpn_mode:-follow}"
    case "$mode" in
    direct) ;;
    *)
        printf '%s' "$nets"
        return 0
        ;;
    esac
    local guest_nets exclude n g skip
    guest_nets=$(vpn_guest_nets_v4)
    for n in $nets; do
        skip=0
        for g in $guest_nets; do
            [ "$n" = "$g" ] && skip=1 && break
        done
        [ "$skip" = "0" ] && printf '%s ' "$n"
    done
}

# ── 6. Preflight ────────────────────────────────────────────────────────────
vpn_preflight_run() {
    load_xrayui_config
    local ok=true
    local ntp_ok=false wan_ok=false tproxy_ok=false xray_ok=false dns_ok=false conflict=false
    local msg="" checks

    # NTP
    if [ "$(nvram get ntp_ready 2>/dev/null)" = "1" ]; then
        ntp_ok=true
    else
        ok=false
        msg="${msg}NTP not synced. "
    fi

    # WAN
    if [ -n "$(nvram get wan0_ipaddr 2>/dev/null)" ] && [ "$(nvram get wan0_ipaddr)" != "0.0.0.0" ]; then
        wan_ok=true
    else
        ok=false
        msg="${msg}WAN has no IP. "
    fi

    # TPROXY module (soft — redirect still works)
    if lsmod 2>/dev/null | grep -q 'xt_TPROXY\|TPROXY'; then
        tproxy_ok=true
    elif iptables -w -t mangle -A "$FW_CHAIN" -p tcp -j TPROXY --on-port 1 --tproxy-mark 1 2>/dev/null; then
        iptables -w -t mangle -D "$FW_CHAIN" -p tcp -j TPROXY --on-port 1 --tproxy-mark 1 2>/dev/null || true
        tproxy_ok=true
    else
        tproxy_ok=false
        msg="${msg}TPROXY unavailable (REDIRECT still OK). "
    fi

    # Xray process
    if [ -n "$(get_xray_daemon_pid 2>/dev/null)" ]; then
        xray_ok=true
    else
        xray_ok=false
        [ -f "$XRAY_DESIRED_STATE_FILE" ] && ok=false && msg="${msg}Xray not running. "
    fi

    # DNS inbound / dnsmasq
    if [ -f "$XRAY_CONFIG_FILE" ] && jq -e '(.inbounds // []) | any(.protocol=="dokodemo-door")' "$XRAY_CONFIG_FILE" >/dev/null 2>&1; then
        dns_ok=true
    else
        dns_ok=false
        msg="${msg}No dokodemo inbound. "
    fi

    if ss_xrayui_running 2>/dev/null; then
        conflict=true
        ok=false
        msg="${msg}Conflict with stock XrayUI. "
    fi

    mkdir -p "$(dirname "$PREFLIGHT_STATUS_FILE")" 2>/dev/null || true
    jq -n \
        --argjson ok "$ok" \
        --argjson ntp "$ntp_ok" \
        --argjson wan "$wan_ok" \
        --argjson tproxy "$tproxy_ok" \
        --argjson xray "$xray_ok" \
        --argjson dns "$dns_ok" \
        --argjson conflict "$conflict" \
        --arg message "${msg:-OK}" \
        --arg checked "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date)" \
        '{
          ok: $ok,
          checked_at: $checked,
          message: $message,
          checks: {
            ntp: $ntp,
            wan: $wan,
            tproxy: $tproxy,
            xray: $xray,
            dokodemo: $dns,
            xrayui_conflict: $conflict
          }
        }' >"${PREFLIGHT_STATUS_FILE}.$$" &&
        mv -f "${PREFLIGHT_STATUS_FILE}.$$" "$PREFLIGHT_STATUS_FILE"

    if [ -d "$ADDON_WEB_DIR" ]; then
        ln -s -f "$PREFLIGHT_STATUS_FILE" "$ADDON_WEB_DIR/preflight-status.json" 2>/dev/null ||
            cp -f "$PREFLIGHT_STATUS_FILE" "$ADDON_WEB_DIR/preflight-status.json" 2>/dev/null || true
    fi

    if [ "$ok" = "true" ]; then
        log_ok "Preflight OK"
        return 0
    fi
    log_warn "Preflight issues: $msg"
    return 1
}
