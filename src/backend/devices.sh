#!/bin/sh
# shellcheck disable=SC2034  # codacy:Unused variables
#
# VPN device log — LAN clients currently using SurfGate (transparent / proxy),
# enriched with local IP, hostname and MAC from leases / ARP / Merlin clientlist.

DEVICES_VPN_JSON="${DEVICES_VPN_JSON:-$ADDON_SHARE_DIR/devices_vpn.json}"
DEVICES_VPN_LOG="${DEVICES_VPN_LOG:-$ADDON_LOGS_DIR/devices_vpn.log}"
DEVICES_VPN_HISTORY_LOG="${DEVICES_VPN_HISTORY_LOG:-$ADDON_LOGS_DIR/devices_vpn_history.log}"
DEVICES_VPN_MAP="${DEVICES_VPN_MAP:-$ADDON_TMP_DIR/devices_ipmap.tsv}"
DEVICES_VPN_SEEN="${DEVICES_VPN_SEEN:-$ADDON_TMP_DIR/devices_vpn_seen.tsv}"

devices_vpn_access_log() {
    load_xrayui_config
    if [ -f "$XRAY_CONFIG_FILE" ]; then
        jq -r --arg access "$ADDON_LOGS_DIR/xray_access.log" \
            '.log.access // $access' "$XRAY_CONFIG_FILE" 2>/dev/null
    else
        echo "$ADDON_LOGS_DIR/xray_access.log"
    fi
}

# Build TSV: ip<TAB>mac<TAB>name
devices_vpn_build_ipmap() {
    local tmp leases f

    mkdir -p "$(dirname "$DEVICES_VPN_MAP")" 2>/dev/null || true
    tmp="${DEVICES_VPN_MAP}.$$"
    : >"$tmp"

    # dnsmasq leases: <epoch> <mac> <ip> <hostname> <client-id>
    for leases in \
        /var/lib/misc/dnsmasq.leases \
        /tmp/dnsmasq.leases \
        /opt/var/lib/misc/dnsmasq.leases \
        /jffs/dnsmasq.leases; do
        [ -f "$leases" ] || continue
        awk 'NF >= 4 {
            mac=tolower($2); ip=$3; name=$4;
            if (name == "*" || name == "") name="";
            if (ip ~ /^[0-9.]+$/ || ip ~ /:/) printf "%s\t%s\t%s\n", ip, mac, name
        }' "$leases" >>"$tmp"
    done

    # ARP table
    if [ -r /proc/net/arp ]; then
        awk 'NR>1 {
            ip=$1; mac=tolower($4);
            if (mac != "00:00:00:00:00:00" && mac ~ /^([0-9a-f]{2}:){5}[0-9a-f]{2}$/)
                printf "%s\t%s\t\n", ip, mac
        }' /proc/net/arp >>"$tmp"
    fi

    # Merlin networkmap / get_clientlist()-shaped JSON
    for f in /tmp/clientlist.json /jffs/.sys/clientlist.json; do
        [ -f "$f" ] || continue
        command -v jq >/dev/null 2>&1 || continue
        jq -r '
          to_entries[]?
          | select(.key | test("^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$"))
          | .key as $mac
          | .value
          | [
              (.ip // .ipaddr // .ipv4 // ""),
              ($mac | ascii_downcase),
              (.nickName // .name // .hostname // .vendor // "")
            ]
          | @tsv
        ' "$f" 2>/dev/null >>"$tmp" || true
    done

    # nvram custom_clientlist: <Name>mac>0>...>...
    if command -v nvram >/dev/null 2>&1; then
        nvram get custom_clientlist 2>/dev/null | tr '<' '\n' | awk -F'>' '
            NF >= 2 {
                name=$1; mac=tolower($2);
                if (mac ~ /^([0-9a-f]{2}:){5}[0-9a-f]{2}$/)
                    printf "\t%s\t%s\n", mac, name
            }
        ' >>"$tmp"
    fi

    # Merge: prefer rows with both ip+mac; keep best name
    awk -F'\t' '
        {
            ip=$1; mac=$2; name=$3;
            if (mac != "") mac_name[mac] = (name != "" ? name : mac_name[mac])
            if (ip != "" && mac != "") {
                ip_mac[ip] = mac
                if (name != "") ip_name[ip] = name
            }
            if (ip != "" && name != "" && !(ip in ip_name)) ip_name[ip] = name
        }
        END {
            for (ip in ip_mac) {
                mac = ip_mac[ip]
                name = (ip in ip_name && ip_name[ip] != "") ? ip_name[ip] : mac_name[mac]
                printf "%s\t%s\t%s\n", ip, mac, name
            }
        }
    ' "$tmp" | sort -u >"$DEVICES_VPN_MAP"
    rm -f "$tmp"
}

# Emit ip<TAB>outbound for LAN sources in recent access log.
devices_vpn_active_ips() {
    local access
    access=$(devices_vpn_access_log)
    [ -f "$access" ] || return 0

    # POSIX awk (BusyBox): extract LAN source IP + outbound tag from access lines.
    # Cap at 1500 lines — full access log can be multi-MB on Merlin tmpfs.
    tail -n 1500 "$access" 2>/dev/null |
        grep -v 'sys:metrics' |
        grep ' accepted ' |
        awk '
            {
                line = $0
                ip = ""
                outbound = ""

                # Locate "from …" then take host before the last :port
                if (match(line, /from [^ ]+/)) {
                    tok = substr(line, RSTART + 5, RLENGTH - 5)  # after "from "
                    sub(/^tcp:/, "", tok)
                    sub(/^udp:/, "", tok)
                    gsub(/^\[/, "", tok)
                    gsub(/\]$/, "", tok)
                    # strip :port (last colon for IPv4; for IPv6 bracket already removed)
                    if (tok ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+$/) {
                        sub(/:[0-9]+$/, "", tok)
                        ip = tok
                    } else if (tok ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {
                        ip = tok
                    }
                }

                # [inbound -> outbound]  or  [inbound >> outbound]
                if (match(line, /\[[^]]+\]/)) {
                    br = substr(line, RSTART + 1, RLENGTH - 2)
                    if ((p = index(br, "->")) > 0) {
                        outbound = substr(br, p + 2)
                    } else if ((p = index(br, ">>")) > 0) {
                        outbound = substr(br, p + 2)
                    }
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", outbound)
                }

                if (ip == "") next
                if (ip ~ /^10\./ || ip ~ /^192\.168\./ || ip ~ /^172\.(1[6-9]|2[0-9]|3[0-1])\./) {
                    last[ip] = outbound
                    if (outbound != "" && outbound != "direct" && outbound != "freedom" && outbound !~ /^blackhole/)
                        pref[ip] = outbound
                }
            }
            END {
                for (ip in last) {
                    ob = (ip in pref) ? pref[ip] : last[ip]
                    printf "%s\t%s\n", ip, ob
                }
            }
        '
}

# Append history lines when a device appears or changes outbound.
devices_vpn_append_history() {
    local joined="$1"
    local now="$2"
    local prev new_seen line ip mac name outbound prev_via

    mkdir -p "$(dirname "$DEVICES_VPN_HISTORY_LOG")" "$(dirname "$DEVICES_VPN_SEEN")" 2>/dev/null || true
    prev="$DEVICES_VPN_SEEN"
    new_seen="${DEVICES_VPN_SEEN}.$$"
    : >"$new_seen"

    [ -f "$prev" ] || : >"$prev"
    [ -f "$DEVICES_VPN_HISTORY_LOG" ] || printf '# SurfGate VPN device history (IP / MAC / name / via)\n' >"$DEVICES_VPN_HISTORY_LOG"

    while IFS=$(printf '\t') read -r ip mac name outbound; do
        [ -n "$ip" ] || continue
        [ -n "$outbound" ] || outbound="vpn"
        [ -n "$mac" ] || mac="—"
        [ -n "$name" ] || name="$ip"
        printf '%s\t%s\n' "$ip" "$outbound" >>"$new_seen"
        prev_via=$(awk -F'\t' -v ip="$ip" '$1==ip { print $2; exit }' "$prev" 2>/dev/null)
        if [ -z "$prev_via" ]; then
            printf '%s  + %-18s %-18s %-20s via %s\n' "$now" "$ip" "$mac" "$name" "$outbound" >>"$DEVICES_VPN_HISTORY_LOG"
        elif [ "$prev_via" != "$outbound" ]; then
            printf '%s  ~ %-18s %-18s %-20s via %s (was %s)\n' "$now" "$ip" "$mac" "$name" "$outbound" "$prev_via" >>"$DEVICES_VPN_HISTORY_LOG"
        fi
    done <"$joined"

    # Devices that dropped off since last snapshot
    while IFS=$(printf '\t') read -r ip prev_via; do
        [ -n "$ip" ] || continue
        if ! awk -F'\t' -v ip="$ip" '$1==ip { found=1; exit } END { exit !found }' "$new_seen" 2>/dev/null; then
            printf '%s  - %-18s left VPN (was %s)\n' "$now" "$ip" "${prev_via:-vpn}" >>"$DEVICES_VPN_HISTORY_LOG"
        fi
    done <"$prev"

    mv -f "$new_seen" "$prev" 2>/dev/null || rm -f "$new_seen"

    # Cap history size
    if [ -f "$DEVICES_VPN_HISTORY_LOG" ]; then
        _hsz=$(wc -c <"$DEVICES_VPN_HISTORY_LOG" 2>/dev/null | tr -d ' ')
        if [ -n "$_hsz" ] && [ "$_hsz" -gt 1048576 ] 2>/dev/null; then
            tail -n 2000 "$DEVICES_VPN_HISTORY_LOG" >"${DEVICES_VPN_HISTORY_LOG}.trim" 2>/dev/null &&
                mv -f "${DEVICES_VPN_HISTORY_LOG}.trim" "$DEVICES_VPN_HISTORY_LOG" 2>/dev/null ||
                rm -f "${DEVICES_VPN_HISTORY_LOG}.trim" 2>/dev/null
        fi
    fi
}

# Refresh JSON + human log. Used by UI poll + CLI.
devices_vpn_refresh() {
    local active_file joined now count

    load_xrayui_config
    mkdir -p "$ADDON_SHARE_DIR" "$ADDON_LOGS_DIR" "$ADDON_TMP_DIR" 2>/dev/null || true

    # Single-flight + throttle — ClientsOnline used to fire this every 4s.
    mkdir -p /tmp/ssurf 2>/dev/null || true
    if which flock >/dev/null 2>&1; then
        # shellcheck disable=SC3023
        exec 8>/tmp/ssurf/devices_vpn.lock
        flock -n 8 || return 0
    fi
    local _stamp=/tmp/ssurf/devices_vpn.stamp
    local _now=0 _prev=0 _age=999
    _now=$(date +%s 2>/dev/null) || _now=0
    _prev=$(cat "$_stamp" 2>/dev/null) || _prev=0
    case "$_prev" in '' | *[!0-9]*) _prev=0 ;; esac
    if [ "$_now" -gt 0 ] && [ "$_prev" -gt 0 ]; then
        _age=$((_now - _prev))
    fi
    # Reuse cached JSON when a poll lands within 15s of the last refresh.
    if [ "$_age" -lt 15 ] && [ -s "$DEVICES_VPN_JSON" ]; then
        return 0
    fi
    [ "$_now" -gt 0 ] && echo "$_now" >"$_stamp"

    # Do NOT auto-enable Xray access log here — it grows into multi-MB files on
    # /tmp (tmpfs) and was a known Merlin OOM path. User enables it in Connection /
    # General Options when they want LAN device tracking.

    devices_vpn_build_ipmap

    active_file="${ADDON_TMP_DIR}/ssurf_vpn_active.$$"
    devices_vpn_active_ips >"$active_file"

    now=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date)
    joined="${ADDON_TMP_DIR}/ssurf_vpn_joined.$$"

    # Join active IPs with ipmap → TSV: ip mac name outbound
    awk -F'\t' '
        FNR==NR { mac_of[$1]=$2; name_of[$1]=$3; next }
        {
            ip=$1; outbound=$2;
            if (ip=="" || seen[ip]++) next;
            mac=(ip in mac_of)?mac_of[ip]:"";
            name=(ip in name_of)?name_of[ip]:"";
            if (name=="") name=(mac!=""?mac:ip);
            printf "%s\t%s\t%s\t%s\n", ip, mac, name, outbound
        }
    ' "$DEVICES_VPN_MAP" "$active_file" >"$joined"

    if [ ! -s "$joined" ]; then
        echo '[]' >"$DEVICES_VPN_JSON"
        {
            echo "# SurfGate VPN devices — $now"
            echo "# 0 device(s) using VPN"
        } >"$DEVICES_VPN_LOG"
        # Still record departures
        : >"${joined}.empty"
        devices_vpn_append_history "${joined}.empty" "$now"
        rm -f "${joined}.empty"
    else
        jq -R -s -c --arg now "$now" '
          split("\n")
          | map(select(length>0))
          | map(split("\t"))
          | map({
              ip: .[0],
              mac: (.[1] // ""),
              name: (.[2] // .[0]),
              outbound: (.[3] // "vpn"),
              last_seen: $now,
              email: []
            })
        ' <"$joined" >"${DEVICES_VPN_JSON}.$$" &&
            mv -f "${DEVICES_VPN_JSON}.$$" "$DEVICES_VPN_JSON"

        {
            echo "# SurfGate VPN devices — $now"
            printf '%-21s %-20s %-24s %s\n' "IP" "MAC" "NAME" "VIA"
            awk -F'\t' '{ printf "%-21s %-20s %-24s %s\n", $1, ($2==""?"—":$2), $3, ($4==""?"vpn":$4) }' "$joined"
            count=$(wc -l <"$joined" | tr -d ' ')
            echo "# $count device(s) using VPN"
        } >"$DEVICES_VPN_LOG"

        devices_vpn_append_history "$joined" "$now"
    fi

    rm -f "$active_file" "$joined"

    # Publish for clients-online UI (extended shape: ip/mac/name/email)
    cp -f "$DEVICES_VPN_JSON" "$XRAYUI_CLIENTS_FILE" 2>/dev/null || true
    return 0
}

devices_vpn_show() {
    devices_vpn_refresh

    local count
    count=$(jq 'length' "$DEVICES_VPN_JSON" 2>/dev/null || echo 0)

    if [ "${USE_COLOR:-0}" -eq 1 ]; then
        printf '\n%b┌─ %bVPN devices%b ────────────────────────────────┐%b\n' "$CBAR" "$CBLD" "$CBAR" "$CRESET"
        printf '%b│%b local clients currently proxied by SurfGate   %b│%b\n' "$CBAR" "$CDIM" "$CBAR" "$CRESET"
        printf '%b└────────────────────────────────────────────────┘%b\n' "$CBAR" "$CRESET"
        printf '  %b%-18s %-18s %-20s %s%b\n' "$CDIM" "IP" "MAC" "NAME" "VIA" "$CRESET"
    else
        echo "=== VPN devices ($count) ==="
        printf '%-18s %-18s %-20s %s\n' "IP" "MAC" "NAME" "VIA"
    fi

    if [ "$count" = "0" ]; then
        if [ "${USE_COLOR:-0}" -eq 1 ]; then
            printf '  %b!%b no LAN clients in recent access log\n' "$CWARN" "$CRESET"
        else
            echo "  (none)"
        fi
        echo "  log: $DEVICES_VPN_LOG"
        return 0
    fi

    jq -r '.[] | [.ip, (if .mac=="" then "—" else .mac end), .name, (.outbound // "vpn")] | @tsv' "$DEVICES_VPN_JSON" 2>/dev/null |
        while IFS=$(printf '\t') read -r ip mac name via; do
            if [ "${USE_COLOR:-0}" -eq 1 ]; then
                printf '  %b✓%b %-18s %-18s %-20s %b%s%b\n' \
                    "$CSUC" "$CRESET" "$ip" "$mac" "$name" "$CINFO" "$via" "$CRESET"
            else
                printf '  %-18s %-18s %-20s %s\n' "$ip" "$mac" "$name" "$via"
            fi
        done

    echo "  log: $DEVICES_VPN_LOG"
}
