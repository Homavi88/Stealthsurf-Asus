#!/bin/sh
# shellcheck disable=SC2034
# Speed test + DNS leak test (panel JSON + CLI)

SPEEDTEST_STATUS_FILE="${SPEEDTEST_STATUS_FILE:-$ADDON_SHARE_DIR/speedtest_status.json}"
DNSTEST_STATUS_FILE="${DNSTEST_STATUS_FILE:-$ADDON_SHARE_DIR/dnstest_status.json}"

# Download payload size (bytes). Keep modest for router CPU / metered links.
SPEEDTEST_DL_BYTES="${SPEEDTEST_DL_BYTES:-5000000}"
SPEEDTEST_UL_BYTES="${SPEEDTEST_UL_BYTES:-2000000}"
SPEEDTEST_DL_URL="${SPEEDTEST_DL_URL:-https://speed.cloudflare.com/__down?bytes=${SPEEDTEST_DL_BYTES}}"
SPEEDTEST_UL_URL="${SPEEDTEST_UL_URL:-https://speed.cloudflare.com/__up}"
SPEEDTEST_LAT_URL="${SPEEDTEST_LAT_URL:-https://1.1.1.1}"
# Fallback download mirrors (tried in order if primary yields no sample)
SPEEDTEST_DL_FALLBACKS="${SPEEDTEST_DL_FALLBACKS:-https://speed.cloudflare.com/__down?bytes=${SPEEDTEST_DL_BYTES} https://proof.ovh.net/files/1Mb.dat http://ipv4.download.thinkbroadband.com/5MB.zip}"

net_tests_publish() {
    local src="$1" webname="$2"
    [ -n "$src" ] && [ -n "$webname" ] || return 0
    [ -d "$ADDON_WEB_DIR" ] || return 0
    ln -s -f "$src" "$ADDON_WEB_DIR/$webname" 2>/dev/null ||
        cp -f "$src" "$ADDON_WEB_DIR/$webname" 2>/dev/null || true
}

net_tests_now() {
    date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date
}

# Mbps from curl %{speed_download|upload} (bytes/sec). Empty → null JSON.
net_tests_bps_to_mbps() {
    awk -v b="$1" 'BEGIN {
      if (b == "" || b + 0 <= 0) { print ""; exit }
      printf "%.2f", (b + 0) * 8 / 1000000
    }'
}

# ── Speed test ──────────────────────────────────────────────────────────────
# Overridable hooks for unit tests (no network).
speedtest_probe_latency_ms() {
    local t
    t=$(curl -sS -o /dev/null -w '%{time_connect}' --connect-timeout 5 --max-time 8 \
        "$SPEEDTEST_LAT_URL" 2>/dev/null) || t=""
    if [ -z "$t" ] || [ "$t" = "0.000000" ]; then
        t=$(curl -sS -o /dev/null -w '%{time_starttransfer}' --connect-timeout 5 --max-time 8 \
            "$SPEEDTEST_LAT_URL" 2>/dev/null) || t=""
    fi
    [ -n "$t" ] || {
        echo ""
        return 1
    }
    awk -v s="$t" 'BEGIN { printf "%.0f", (s + 0) * 1000 }'
}

speedtest_probe_download_url() {
    # $1=url — Prints: speed_bps size_bytes time_total
    local url="$1"
    [ -n "$url" ] || return 1
    curl -sS -o /dev/null -w '%{speed_download} %{size_download} %{time_total}' \
        --connect-timeout 10 --max-time 45 \
        -L "$url" 2>/dev/null
}

speedtest_probe_download() {
    # Try primary + fallbacks until we get a non-empty speed sample.
    # Prints: speed_bps size_bytes time_total used_url
    # (used_url is a field — command substitution would drop a global assign)
    local url out bps
    for url in $SPEEDTEST_DL_URL $SPEEDTEST_DL_FALLBACKS; do
        [ -n "$url" ] || continue
        out=$(speedtest_probe_download_url "$url" 2>/dev/null || true)
        bps=$(printf '%s' "$out" | awk '{print $1}')
        if [ -n "$bps" ] && awk -v b="$bps" 'BEGIN{exit !(b+0 > 0)}'; then
            # Keep first three curl fields; append URL as $4
            printf '%s %s\n' "$(printf '%s' "$out" | awk '{print $1" "$2" "$3}')" "$url"
            return 0
        fi
    done
    echo ""
    return 1
}

speedtest_probe_upload() {
    # Prints: speed_bps
    # Prefer dd|curl; fall back to skipping upload.
    if ! command -v dd >/dev/null 2>&1; then
        echo ""
        return 1
    fi
    dd if=/dev/zero bs="$SPEEDTEST_UL_BYTES" count=1 2>/dev/null |
        curl -sS -o /dev/null -w '%{speed_upload}' \
            -X POST --data-binary @- \
            --connect-timeout 10 --max-time 45 \
            -H 'Content-Type: application/octet-stream' \
            "$SPEEDTEST_UL_URL" 2>/dev/null
}

speedtest_run() {
    load_xrayui_config 2>/dev/null || true
    update_loading_progress "Speed test: measuring…" 20 2>/dev/null || true

    local lat_ms="" dl_bps="" dl_bytes="" dl_time="" ul_bps=""
    local dl_mbps="" ul_mbps="" ok=false msg="" server="auto"
    SPEEDTEST_USED_URL=""

    lat_ms=$(speedtest_probe_latency_ms 2>/dev/null || true)
    update_loading_progress "Speed test: download…" 45 2>/dev/null || true

    set -- $(speedtest_probe_download 2>/dev/null || true)
    dl_bps=${1:-}
    dl_bytes=${2:-}
    dl_time=${3:-}
    SPEEDTEST_USED_URL=${4:-}
    [ -n "$SPEEDTEST_USED_URL" ] && server="$SPEEDTEST_USED_URL"

    update_loading_progress "Speed test: upload…" 70 2>/dev/null || true
    ul_bps=$(speedtest_probe_upload 2>/dev/null || true)

    dl_mbps=$(net_tests_bps_to_mbps "$dl_bps")
    ul_mbps=$(net_tests_bps_to_mbps "$ul_bps")

    if [ -n "$dl_mbps" ]; then
        ok=true
        msg="${dl_mbps} Mbps ↓"
        [ -n "$ul_mbps" ] && msg="$msg / ${ul_mbps} Mbps ↑"
        [ -n "$lat_ms" ] && msg="$msg · ${lat_ms} ms"
    else
        ok=false
        msg="Speed test failed (no download sample). Check WAN / DNS."
    fi

    mkdir -p "$(dirname "$SPEEDTEST_STATUS_FILE")" 2>/dev/null || true
    jq -n \
        --argjson ok "$ok" \
        --arg message "$msg" \
        --arg checked "$(net_tests_now)" \
        --arg server "$server" \
        --arg dl_url "${SPEEDTEST_USED_URL:-$SPEEDTEST_DL_URL}" \
        --arg latency_ms "${lat_ms}" \
        --arg download_mbps "${dl_mbps}" \
        --arg upload_mbps "${ul_mbps}" \
        --arg download_bytes "${dl_bytes}" \
        --arg download_seconds "${dl_time}" \
        '{
          ok: $ok,
          checked_at: $checked,
          message: $message,
          server: $server,
          latency_ms: (if $latency_ms == "" then null else ($latency_ms | tonumber) end),
          download_mbps: (if $download_mbps == "" then null else ($download_mbps | tonumber) end),
          upload_mbps: (if $upload_mbps == "" then null else ($upload_mbps | tonumber) end),
          download_bytes: (if $download_bytes == "" then null else ($download_bytes | tonumber) end),
          download_seconds: (if $download_seconds == "" then null else ($download_seconds | tonumber) end),
          download_url: $dl_url
        }' >"${SPEEDTEST_STATUS_FILE}.$$" &&
        mv -f "${SPEEDTEST_STATUS_FILE}.$$" "$SPEEDTEST_STATUS_FILE"

    net_tests_publish "$SPEEDTEST_STATUS_FILE" "speedtest-status.json"

    if [ "$ok" = "true" ]; then
        log_ok "Speed test: $msg"
        return 0
    fi
    log_warn "Speed test: $msg"
    return 1
}

# ── DNS leak test ───────────────────────────────────────────────────────────
dnstest_has_dns_wiring() {
    [ -f "$XRAY_CONFIG_FILE" ] || return 1
    jq -e '(.outbounds // []) | any(.tag == "sys:dns-out")' "$XRAY_CONFIG_FILE" >/dev/null 2>&1
}

dnstest_has_dokodemo_dns() {
    [ -f "$XRAY_CONFIG_FILE" ] || return 1
    jq -e '
      (.inbounds // [])
      | any(
          .protocol == "dokodemo-door"
          and (.settings.port // 0) == 53
          and (.settings.followRedirect != true)
        )
    ' "$XRAY_CONFIG_FILE" >/dev/null 2>&1
}

dnstest_has_firewall_lock() {
    local chain="${ADDON_TAG_UPPER}_DNSLOCK"
    iptables -w -t filter -L "$chain" -n >/dev/null 2>&1
}

dnstest_exit_ip() {
    local ip=""
    for url in \
        "https://api.ipify.org" \
        "https://ifconfig.me/ip" \
        "https://icanhazip.com"; do
        ip=$(curl -fsS --connect-timeout 5 --max-time 10 "$url" 2>/dev/null | tr -d '\r\n[:space:]')
        # crude IPv4/IPv6 sanity
        echo "$ip" | grep -Eq '^[0-9a-fA-F:.]+$' || continue
        echo "$ip"
        return 0
    done
    echo ""
    return 1
}

# Optional IPv6 exit (empty if unreachable / disabled).
dnstest_exit_ip6() {
    local ip=""
    for url in \
        "https://api64.ipify.org" \
        "https://ipv6.icanhazip.com"; do
        ip=$(curl -6 -fsS --connect-timeout 5 --max-time 10 "$url" 2>/dev/null | tr -d '\r\n[:space:]')
        echo "$ip" | grep -Eq '^[0-9a-fA-F:]+$' || continue
        echo "$ip"
        return 0
    done
    echo ""
    return 1
}

# Prints JSON array of {ip,isp,country} — override in tests.
dnstest_fetch_resolvers_json() {
    local raw=""
    raw=$(curl -fsS --connect-timeout 8 --max-time 20 "https://ipleak.net/json/" 2>/dev/null) || raw=""
    if [ -n "$raw" ] && echo "$raw" | jq -e . >/dev/null 2>&1; then
        # ipleak shapes vary: dns_servers as object map or array
        echo "$raw" | jq -c '
          def row:
            if type == "object" then
              {ip: (.ip // .), isp: (.isp // .asn_name // .org // ""), country: (.country_code // .country_name // .country // "")}
            elif type == "string" then
              {ip: ., isp: "", country: ""}
            else empty end;
          if (.dns_servers | type) == "object" then
            [.dns_servers | to_entries[] | (.value | row)]
          elif (.dns_servers | type) == "array" then
            [.dns_servers[] | row]
          else [] end
        ' 2>/dev/null && return 0
    fi

    # Fallback: bash.ws DNS leak API
    local id i
    id=$(awk 'BEGIN { srand(); printf "%d", 10000000 + int(rand() * 89999999) }')
    for i in 1 2 3 4 5 6; do
        if command -v dig >/dev/null 2>&1; then
            dig +short +time=2 +tries=1 "$i.$id.bash.ws" >/dev/null 2>&1 || true
        elif command -v nslookup >/dev/null 2>&1; then
            nslookup "$i.$id.bash.ws" >/dev/null 2>&1 || true
        else
            break
        fi
    done
    raw=$(curl -fsS --connect-timeout 8 --max-time 20 "https://bash.ws/dnsleak/id/$id?json" 2>/dev/null) || raw=""
    if [ -n "$raw" ] && echo "$raw" | jq -e . >/dev/null 2>&1; then
        echo "$raw" | jq -c '
          [ .[]?
            | select((.type // "") == "dns")
            | {ip: (.ip // ""), isp: (.asn // .org // ""), country: (.country_name // .country // "")}
          ]
        ' 2>/dev/null && return 0
    fi
    echo '[]'
}

dnstest_wan_dns_list() {
    # Space-separated resolver IPs from NVRAM / resolv.conf
    local out=""
    out=$(nvram get wan0_dns 2>/dev/null)
    out="$out $(nvram get wan_dns 2>/dev/null)"
    out="$out $(nvram get wan0_xdns 2>/dev/null)"
    if [ -r /etc/resolv.conf ]; then
        out="$out $(awk '/^nameserver/ {print $2}' /etc/resolv.conf 2>/dev/null)"
    fi
    echo "$out" | tr ',;' ' ' | tr -s ' ' | sed 's/^ //;s/ $//'
}

dnstest_run() {
    load_xrayui_config 2>/dev/null || true
    update_loading_progress "DNS leak test…" 25 2>/dev/null || true

    local dns_only_flag=false wiring=false dokodemo=false fwlock=false
    local exit_ip="" exit_ip6="" resolvers_json="[]" wan_dns=""
    local leaked=false ipv6_leaked=false ok=true msg="" overlap=""
    local ipv6_mode_now="${ipv6_mode:-proxy}"

    [ "${xray_dns_only:-false}" = "true" ] && dns_only_flag=true
    dnstest_has_dns_wiring && wiring=true
    dnstest_has_dokodemo_dns && dokodemo=true
    dnstest_has_firewall_lock && fwlock=true

    update_loading_progress "DNS leak test: exit IP…" 45 2>/dev/null || true
    exit_ip=$(dnstest_exit_ip 2>/dev/null || true)
    exit_ip6=$(dnstest_exit_ip6 2>/dev/null || true)

    update_loading_progress "DNS leak test: resolvers…" 70 2>/dev/null || true
    resolvers_json=$(dnstest_fetch_resolvers_json 2>/dev/null || echo '[]')
    echo "$resolvers_json" | jq -e 'type=="array"' >/dev/null 2>&1 || resolvers_json='[]'

    wan_dns=$(dnstest_wan_dns_list)

    # Overlap: public leak-test resolvers that match WAN/system DNS → ISP leak signal
    overlap=$(printf '%s\n' "$resolvers_json" | jq -r --arg wan "$wan_dns" '
      ($wan | split(" ") | map(select(length>0))) as $w
      | [.[] | .ip | select(. as $ip | ($w | index($ip)))]
      | unique | join(" ")
    ' 2>/dev/null)

    # IPv6 leak: mode=block but we still have a public IPv6 exit
    if [ "$ipv6_mode_now" = "block" ] && [ -n "$exit_ip6" ]; then
        ipv6_leaked=true
    fi

    if [ -n "$overlap" ]; then
        leaked=true
        ok=false
        msg="DNS leak: resolver(s) match WAN DNS ($overlap)."
    elif [ "$ipv6_leaked" = "true" ]; then
        leaked=true
        ok=false
        msg="IPv6 leak: ipv6_mode=block but exit IPv6 is $exit_ip6."
    elif [ "$dns_only_flag" = "true" ] || [ "$wiring" = "true" ]; then
        if [ "$dokodemo" != "true" ]; then
            ok=false
            msg="DNS protection on, but no dokodemo :53 inbound."
        elif [ "$dns_only_flag" = "true" ] && [ "$fwlock" != "true" ]; then
            ok=false
            msg="dns_only on, but firewall DNS lock not active."
        else
            ok=true
            leaked=false
            msg="No ISP DNS leak detected."
            [ -n "$exit_ip" ] && msg="$msg Exit IP $exit_ip."
            [ -n "$exit_ip6" ] && msg="$msg IPv6 $exit_ip6."
        fi
    else
        # Protection off — still report; not a failure unless overlap found
        ok=true
        leaked=false
        msg="DNS leak lock off (enable «DNS только через Xray» for hardening)."
        [ -n "$exit_ip" ] && msg="$msg Exit IP $exit_ip."
        [ -n "$exit_ip6" ] && msg="$msg IPv6 $exit_ip6."
        if [ "$(printf '%s' "$resolvers_json" | jq 'length')" -eq 0 ]; then
            msg="$msg (resolver probe unavailable)."
        fi
    fi
    msg="$msg WebRTC: check from a LAN browser (browserleaks.com/webrtc)."

    mkdir -p "$(dirname "$DNSTEST_STATUS_FILE")" 2>/dev/null || true
    jq -n \
        --argjson ok "$ok" \
        --argjson leaked "$leaked" \
        --argjson ipv6_leaked "$ipv6_leaked" \
        --argjson dns_only "$dns_only_flag" \
        --argjson dns_wiring "$wiring" \
        --argjson dokodemo_dns "$dokodemo" \
        --argjson firewall_lock "$fwlock" \
        --argjson resolvers "$resolvers_json" \
        --arg exit_ip "${exit_ip}" \
        --arg exit_ip6 "${exit_ip6}" \
        --arg ipv6_mode "$ipv6_mode_now" \
        --arg wan_dns "${wan_dns}" \
        --arg overlap "${overlap}" \
        --arg message "$msg" \
        --arg checked "$(net_tests_now)" \
        '{
          ok: $ok,
          checked_at: $checked,
          message: $message,
          leaked: $leaked,
          ipv6_leaked: $ipv6_leaked,
          ipv6_mode: $ipv6_mode,
          exit_ip: (if $exit_ip == "" then null else $exit_ip end),
          exit_ip6: (if $exit_ip6 == "" then null else $exit_ip6 end),
          wan_dns: $wan_dns,
          overlap: $overlap,
          dns_only: $dns_only,
          dns_wiring: $dns_wiring,
          dokodemo_dns: $dokodemo_dns,
          firewall_lock: $firewall_lock,
          resolvers: $resolvers,
          webrtc_hint: "https://browserleaks.com/webrtc"
        }' >"${DNSTEST_STATUS_FILE}.$$" &&
        mv -f "${DNSTEST_STATUS_FILE}.$$" "$DNSTEST_STATUS_FILE"

    net_tests_publish "$DNSTEST_STATUS_FILE" "dnstest-status.json"

    if [ "$ok" = "true" ]; then
        log_ok "DNS leak test: $msg"
        return 0
    fi
    log_warn "DNS leak test: $msg"
    return 1
}
