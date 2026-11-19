#!/bin/sh
# shellcheck disable=SC2034
# Boot / WAN / kill-switch / LAN device mode / IPv6 / guest / preflight

FW_KILLSWITCH_CHAIN="${ADDON_TAG_UPPER}_KILLSWITCH"
FW_SVCLOCK_CHAIN="${FW_SVCLOCK_CHAIN:-${ADDON_TAG_UPPER}_SVCLOCK}"
IPSET_LOCK_V4="${IPSET_LOCK_V4:-${ADDON_TAG_UPPER}_LOCK4}"
IPSET_LOCK_V6="${IPSET_LOCK_V6:-${ADDON_TAG_UPPER}_LOCK6}"
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

    if ss_xrayui_running 2>/dev/null || ss_official_running 2>/dev/null; then
        log_warn "WAN reconnect: another transparent VPN addon active — skip SurfGate restore"
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
    vpn_service_lock_apply 2>/dev/null || true
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
# follow = same as main LAN policy (selected/exclude apply to guest too)
# vpn    = always TPROXY guest bridges even when lan_vpn_mode=selected/exclude
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

# Filter source_nets list: when guest_vpn_mode=direct, drop guest CIDRs.
# When guest_vpn_mode=vpn, ensure guest CIDRs stay listed (union with detected guest nets).
vpn_filter_source_nets() {
    local nets="$1"
    local mode="${guest_vpn_mode:-follow}"
    case "$mode" in
    direct)
        local guest_nets n g skip
        guest_nets=$(vpn_guest_nets_v4)
        for n in $nets; do
            skip=0
            for g in $guest_nets; do
                [ "$n" = "$g" ] && skip=1 && break
            done
            [ "$skip" = "0" ] && printf '%s ' "$n"
        done
        ;;
    vpn)
        printf '%s\n' $nets $(vpn_guest_nets_v4) | sed '/^$/d' | sort -u | tr '\n' ' '
        ;;
    *)
        printf '%s' "$nets"
        ;;
    esac
}

# True when guest must be forced through TPROXY regardless of MAC policies.
vpn_guest_force_wanted() {
    [ "${guest_vpn_mode:-follow}" = "vpn" ]
}

# Print guest IPv4 CIDRs for forced redirect (empty if not wanted / none found).
vpn_guest_force_nets() {
    vpn_guest_force_wanted || return 0
    vpn_guest_nets_v4
}

# ── Domain helpers (bypass / VPN-lock) ──────────────────────────────────────
vpn_domains_to_json() {
    printf '%s' "${1:-}" | tr ';\n' ',,' | tr -s ',' ',' | sed 's/^,//; s/,$//' |
        awk -F',' '
          BEGIN { printf "[" }
          {
            n=0
            for (i=1;i<=NF;i++) {
              gsub(/^[ \t]+|[ \t]+$/, "", $i)
              if ($i=="") continue
              if (n++) printf ","
              printf "\"%s\"", $i
            }
          }
          END { printf "]" }
        '
}

vpn_lock_wanted() {
    load_xrayui_config 2>/dev/null || true
    local raw="${split_lock_domains:-}"
    [ -n "$(printf '%s' "$raw" | tr -d ' \t\n\r,;')" ]
}

# Prefer tag "proxy", else first non-direct/non-block outbound
vpn_primary_proxy_tag() {
    [ -f "$XRAY_CONFIG_FILE" ] || {
        echo "proxy"
        return 0
    }
    jq -r '
      (.outbounds // []) as $o
      | ($o | map(select(
          (.protocol // "") != "freedom"
          and (.protocol // "") != "blackhole"
          and (.protocol // "") != "dns"
          and ((.tag // "") != "direct")
          and ((.tag // "") != "block")
          and ((.tag // "") != "")
        ))) as $p
      | (($p | map(select(.tag == "proxy"))) + $p)
      | if length == 0 then "proxy" else .[0].tag end
    ' "$XRAY_CONFIG_FILE" 2>/dev/null || echo "proxy"
}

# Preset: Russian TLDs → direct (.рф as punycode xn--p1ai for dnsmasq/ipset)
vpn_split_ru_tld_domains() {
    printf '%s' 'domain:ru,domain:su,domain:xn--p1ai'
}

# Preset: RU services whitelist → direct (geosite where available + literals)
vpn_split_ru_services_domains() {
    printf '%s' \
        'geosite:category-ru,geosite:category-gov-ru,geosite:geolocation-ru,geosite:yandex,' \
        'gosuslugi.ru,mos.ru,nalog.ru,cbr.ru,' \
        'sberbank.ru,sber.ru,tinkoff.ru,tbank.ru,vtb.ru,alfabank.ru,gazprombank.ru,raiffeisen.ru,' \
        'vk.com,vk.ru,ok.ru,mail.ru,my.mail.ru,yandex.ru,ya.ru,yandex.net,yandex.com,' \
        'ozon.ru,wildberries.ru,wb.ru,avito.ru,dns-shop.ru,citilink.ru,mvideo.ru,' \
        'mts.ru,megafon.ru,beeline.ru,tele2.ru,t2.ru,rostelecom.ru,' \
        'rutube.ru,kinopoisk.ru,ivi.ru,okko.tv,premier.one,' \
        'rbc.ru,ria.ru,tass.ru,lenta.ru,kommersant.ru'
}

# ── Domain split (bypass list → direct) ─────────────────────────────────────
# split_bypass_domains: comma/space/newline separated hostnames or geosite: tags
# + optional presets: split_bypass_ru_tlds / split_bypass_ru_services
vpn_split_rules_sync() {
    load_xrayui_config
    local raw="${split_bypass_domains:-}"
    local tmp domains_json

    [ -f "$XRAY_CONFIG_FILE" ] || return 0

    case "${split_bypass_ru_tlds:-false}" in
    true | 1 | yes | on)
        raw="${raw},$(vpn_split_ru_tld_domains)"
        ;;
    esac
    case "${split_bypass_ru_services:-false}" in
    true | 1 | yes | on)
        raw="${raw},$(vpn_split_ru_services_domains)"
        ;;
    esac

    # Normalise → JSON string array (keep geosite: / domain: / full: prefixes)
    domains_json=$(vpn_domains_to_json "$raw")

    tmp="${ADDON_TMP_DIR}/ssurf_split.$$"
    mkdir -p "$ADDON_TMP_DIR" 2>/dev/null || true

    if [ "$domains_json" = "[]" ] || [ -z "$domains_json" ]; then
        jq '
          .routing = (.routing // {})
          | .routing.rules = (
              [(.routing.rules // [])[] | select((.name // "") != "surfgate-split-bypass")]
            )
        ' "$XRAY_CONFIG_FILE" >"$tmp" && mv -f "$tmp" "$XRAY_CONFIG_FILE"
        log_info "Split bypass domains cleared"
        return 0
    fi

    # Ensure a freedom/direct outbound exists for bypass
    if ! jq -e '(.outbounds // []) | any(.tag=="direct")' "$XRAY_CONFIG_FILE" >/dev/null 2>&1; then
        jq '
          .outbounds = ((.outbounds // []) + [{tag:"direct",protocol:"freedom",settings:{}}])
        ' "$XRAY_CONFIG_FILE" >"$tmp" && mv -f "$tmp" "$XRAY_CONFIG_FILE"
    fi

    jq --argjson domains "$domains_json" '
      .routing = (.routing // {})
      | .routing.rules = (
          [{
            name: "surfgate-split-bypass",
            type: "field",
            domain: $domains,
            outboundTag: "direct"
          }]
          + [(.routing.rules // [])[] | select((.name // "") != "surfgate-split-bypass")]
        )
    ' "$XRAY_CONFIG_FILE" >"$tmp" && mv -f "$tmp" "$XRAY_CONFIG_FILE"
    rm -f "$tmp" 2>/dev/null
    log_info "Split bypass domains applied ($domains_json)"
}

# ── VPN-only / fail-closed lock (domains must use VPN or be blocked) ────────
# split_lock_domains: hostnames or geosite: tags → proxy outbound in Xray;
# literal hostnames also feed LOCK ipsets; unmarked clearnet to those IPs is DROP.
vpn_lock_rules_sync() {
    load_xrayui_config
    local raw="${split_lock_domains:-}"
    local tmp domains_json proxy_tag

    [ -f "$XRAY_CONFIG_FILE" ] || return 0

    domains_json=$(vpn_domains_to_json "$raw")
    tmp="${ADDON_TMP_DIR}/ssurf_lock.$$"
    mkdir -p "$ADDON_TMP_DIR" 2>/dev/null || true

    if [ "$domains_json" = "[]" ] || [ -z "$domains_json" ]; then
        jq '
          .routing = (.routing // {})
          | .routing.rules = (
              [(.routing.rules // [])[] | select((.name // "") != "surfgate-vpn-lock")]
            )
        ' "$XRAY_CONFIG_FILE" >"$tmp" && mv -f "$tmp" "$XRAY_CONFIG_FILE"
        log_info "VPN-lock domains cleared"
        return 0
    fi

    proxy_tag=$(vpn_primary_proxy_tag)
    # Ensure target outbound exists (scaffold / import usually provides it)
    if ! jq -e --arg t "$proxy_tag" '(.outbounds // []) | any(.tag==$t)' "$XRAY_CONFIG_FILE" >/dev/null 2>&1; then
        log_warn "VPN-lock: outbound tag '$proxy_tag' missing — rule still written"
    fi

    # Place lock before bypass so a domain listed in both stays fail-closed on VPN
    jq --argjson domains "$domains_json" --arg tag "$proxy_tag" '
      .routing = (.routing // {})
      | .routing.rules = (
          [{
            name: "surfgate-vpn-lock",
            type: "field",
            domain: $domains,
            outboundTag: $tag
          }]
          + [(.routing.rules // [])[] | select((.name // "") != "surfgate-vpn-lock")]
        )
    ' "$XRAY_CONFIG_FILE" >"$tmp" && mv -f "$tmp" "$XRAY_CONFIG_FILE"
    rm -f "$tmp" 2>/dev/null
    log_info "VPN-lock domains applied → $proxy_tag ($domains_json)"
}

vpn_lock_ensure_sets() {
    ipset list -t "$IPSET_LOCK_V4" >/dev/null 2>&1 ||
        ipset create "$IPSET_LOCK_V4" hash:ip family inet timeout 86400 2>/dev/null ||
        ipset create "$IPSET_LOCK_V4" hash:ip family inet 2>/dev/null || true
    if is_ipv6_enabled 2>/dev/null; then
        ipset list -t "$IPSET_LOCK_V6" >/dev/null 2>&1 ||
            ipset create "$IPSET_LOCK_V6" hash:ip family inet6 timeout 86400 2>/dev/null ||
            ipset create "$IPSET_LOCK_V6" hash:ip family inet6 2>/dev/null || true
    fi
}

# Best-effort resolve literal hostnames into LOCK sets (geosite: skipped)
vpn_lock_prime_ips() {
    load_xrayui_config
    vpn_lock_ensure_sets
    local raw="${split_lock_domains:-}" d ip
    printf '%s' "$raw" | tr ';\n' ',,' | tr ',' '\n' | while IFS= read -r d; do
        d=$(printf '%s' "$d" | sed 's/^[ \t]*//;s/[ \t]*$//')
        [ -z "$d" ] && continue
        case "$d" in
        geosite:* | geoip:* | ext:* | domain:* | full:* | regexp:* | keyword:*) continue ;;
        esac
        # strip leading wildcard / dots for resolve
        d=$(printf '%s' "$d" | sed 's/^\*\.//; s/^\.//')
        [ -z "$d" ] && continue
        for ip in $(nslookup "$d" 2>/dev/null | awk '/^Address: / { print $2 }' | grep -E '^[0-9.]+$|^[0-9a-fA-F:]+$'); do
            case "$ip" in
            *:*) ipset add "$IPSET_LOCK_V6" "$ip" 2>/dev/null || true ;;
            *) ipset add "$IPSET_LOCK_V4" "$ip" 2>/dev/null || true ;;
            esac
        done
    done
}

vpn_service_lock_clear() {
    local IPT
    for IPT in iptables ip6tables; do
        command -v "$IPT" >/dev/null 2>&1 || continue
        $IPT -w -t filter -D FORWARD -j "$FW_SVCLOCK_CHAIN" 2>/dev/null || true
        $IPT -w -t filter -D OUTPUT -j "$FW_SVCLOCK_CHAIN" 2>/dev/null || true
        $IPT -w -t filter -F "$FW_SVCLOCK_CHAIN" 2>/dev/null || true
        $IPT -w -t filter -X "$FW_SVCLOCK_CHAIN" 2>/dev/null || true
    done
}

vpn_service_lock_conntrack_flush() {
    command -v conntrack >/dev/null 2>&1 || return 0
    local ip
    if ipset list -t "$IPSET_LOCK_V4" >/dev/null 2>&1; then
        for ip in $(ipset list "$IPSET_LOCK_V4" 2>/dev/null | awk '/^[0-9]+\./ { print $1 }'); do
            conntrack -D -d "$ip" 2>/dev/null || true
            conntrack -D -q "$ip" 2>/dev/null || true
        done
    fi
    if is_ipv6_enabled 2>/dev/null && ipset list -t "$IPSET_LOCK_V6" >/dev/null 2>&1; then
        for ip in $(ipset list "$IPSET_LOCK_V6" 2>/dev/null | awk '/:/ { print $1 }'); do
            conntrack -D -f ipv6 -d "$ip" 2>/dev/null || true
            conntrack -D -f ipv6 -q "$ip" 2>/dev/null || true
        done
    fi
}

vpn_service_lock_apply() {
    load_xrayui_config
    vpn_service_lock_clear

    if ! vpn_lock_wanted; then
        log_debug "VPN-lock: no domains — not arming"
        return 0
    fi

    vpn_lock_ensure_sets
    vpn_lock_prime_ips

    local IPT wan0 wan1
    wan0=$(nvram get wan0_ifname 2>/dev/null)
    wan1=$(nvram get wan1_ifname 2>/dev/null)

    log_info "Arming VPN-lock (DROP clearnet to locked service IPs)…"

    for IPT in iptables ip6tables; do
        command -v "$IPT" >/dev/null 2>&1 || continue
        if [ "$IPT" = "ip6tables" ]; then
            case "${ipv6_mode:-proxy}" in
            ignore) continue ;;
            esac
            is_ipv6_enabled 2>/dev/null || continue
            ipset list -t "$IPSET_LOCK_V6" >/dev/null 2>&1 || continue
        else
            ipset list -t "$IPSET_LOCK_V4" >/dev/null 2>&1 || continue
        fi

        $IPT -w -t filter -N "$FW_SVCLOCK_CHAIN" 2>/dev/null || $IPT -w -t filter -F "$FW_SVCLOCK_CHAIN"
        # SurfGate-marked / diverted traffic may leave via WAN
        $IPT -w -t filter -A "$FW_SVCLOCK_CHAIN" -m mark --mark "$tproxy_mark/$tproxy_mask" -j RETURN
        # Destination not in lock set → ignore
        if [ "$IPT" = "iptables" ]; then
            $IPT -w -t filter -A "$FW_SVCLOCK_CHAIN" -m set ! --match-set "$IPSET_LOCK_V4" dst -j RETURN
        else
            $IPT -w -t filter -A "$FW_SVCLOCK_CHAIN" -m set ! --match-set "$IPSET_LOCK_V6" dst -j RETURN
        fi
        # Locked destination without SurfGate mark → DROP (all states — cut leaks immediately)
        if [ -n "$wan0" ]; then
            $IPT -w -t filter -A "$FW_SVCLOCK_CHAIN" -o "$wan0" -j DROP
        fi
        if [ -n "$wan1" ] && [ "$wan1" != "$wan0" ]; then
            $IPT -w -t filter -A "$FW_SVCLOCK_CHAIN" -o "$wan1" -j DROP
        fi
        # Also block when oif unknown but dst is locked (router OUTPUT / odd paths)
        $IPT -w -t filter -A "$FW_SVCLOCK_CHAIN" -j DROP

        $IPT -w -t filter -I FORWARD 1 -j "$FW_SVCLOCK_CHAIN"
        $IPT -w -t filter -I OUTPUT 1 -j "$FW_SVCLOCK_CHAIN"
    done

    log_ok "VPN-lock armed"
}

# After Xray stops: cut live sessions and keep fail-closed DROP + dnsmasq LOCK fills
vpn_service_lock_on_xray_down() {
    load_xrayui_config 2>/dev/null || true
    if ! vpn_lock_wanted; then
        vpn_service_lock_clear
        return 0
    fi
    vpn_service_lock_conntrack_flush
    vpn_service_lock_apply
    if type dnsmasq_configure >/dev/null 2>&1; then
        dnsmasq_configure /etc/dnsmasq.conf 2>/dev/null || true
        if type dnsmasq_restart >/dev/null 2>&1; then
            dnsmasq_restart 2>/dev/null || true
        fi
    fi
}

# Append ipset=/domain/LOCK… lines for literal lock hostnames (into open dnsmasq conf)
vpn_lock_dnsmasq_append() {
    local CONFIG="${1:-/etc/dnsmasq.conf}"
    load_xrayui_config 2>/dev/null || true
    vpn_lock_wanted || return 0
    vpn_lock_ensure_sets

    local raw="${split_lock_domains:-}" d sets
    sets="$IPSET_LOCK_V4"
    if is_ipv6_enabled 2>/dev/null; then
        sets="$IPSET_LOCK_V4,$IPSET_LOCK_V6"
    fi
    # When redirect mode is active, also fill PROXY so traffic is diverted into Xray
    if [ "${ipsec:-off}" = "redirect" ]; then
        if is_ipv6_enabled 2>/dev/null; then
            sets="$IPSET_LOCK_V4,$IPSET_LOCK_V6,$IPSET_PROXY_V4,$IPSET_PROXY_V6"
        else
            sets="$IPSET_LOCK_V4,$IPSET_PROXY_V4"
        fi
    fi

    printf '%s' "$raw" | tr ';\n' ',,' | tr ',' '\n' | while IFS= read -r d; do
        d=$(printf '%s' "$d" | sed 's/^[ \t]*//;s/[ \t]*$//')
        [ -z "$d" ] && continue
        case "$d" in
        geosite:* | geoip:* | ext:* | regexp:* | keyword:*) continue ;;
        domain:*) d="${d#domain:}" ;;
        full:*) d="${d#full:}" ;;
        esac
        d=$(printf '%s' "$d" | sed 's/^\*\.//')
        [ -z "$d" ] && continue
        # basic hostname sanity
        printf '%s' "$d" | grep -qE '^[A-Za-z0-9._-]+$' || continue
        pc_append "ipset=/$d/$sets" "$CONFIG" 2>/dev/null ||
            printf 'ipset=/%s/%s\n' "$d" "$sets" >>"$CONFIG"
    done
    return 0
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
    if ss_official_running 2>/dev/null; then
        conflict=true
        ok=false
        msg="${msg}Conflict with official StealthSurf. "
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
