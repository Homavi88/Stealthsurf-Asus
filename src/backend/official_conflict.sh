#!/bin/sh
# Detect official StealthSurf VPN (stealthsurf-routerd) dataplane conflict.
# Paths/settings are isolated under /jffs/addons/ssurf, but two transparent
# proxies on one LAN break routing — refuse SurfGate start while official runs.
#
# Important: "installed but stopped" must NOT count as running. Official stop
# often leaves STEALTHSURF_* iptables chains behind; those orphans used to keep
# SurfGate blocked until the official package was deleted. Detection is process-
# based; orphan chains are cleaned when the daemon is confirmed down.

SS_OFFICIAL_CACHE="${SS_OFFICIAL_CACHE:-/tmp/stealthsurf.official.cache}"
SS_OFFICIAL_CACHE_TTL="${SS_OFFICIAL_CACHE_TTL:-45}"
SS_OFFICIAL_MSG_RU="Конфликт с официальным StealthSurf — сейчас работает stealthsurf-routerd. Остановите VPN в приложении StealthSurf (или службу на роутере), затем запускайте SurfGate. Одновременно оба нельзя: два transparent-proxy ломают интернет в LAN."

ss_official_installed() {
    [ -n "${OFFICIAL_SS_DAEMON:-}" ] && [ -x "$OFFICIAL_SS_DAEMON" ] && return 0
    [ -n "${OFFICIAL_SS_JFFS_DIR:-}" ] && [ -d "$OFFICIAL_SS_JFFS_DIR/sbin" ] && return 0
    [ -d /jffs/addons/stealthsurf/sbin ] && return 0
    return 1
}

ss_official_process_running() {
    local line="" p cmd
    if command -v ps >/dev/null 2>&1; then
        # shellcheck disable=SC2009
        line=$(ps w 2>/dev/null | grep '[s]tealthsurf-routerd' | head -1)
        [ -n "$line" ] && return 0
        return 1
    fi
    for p in /proc/[0-9]*; do
        [ -r "$p/cmdline" ] || continue
        cmd=$(tr '\0' ' ' <"$p/cmdline" 2>/dev/null)
        case "$cmd" in
        *stealthsurf-routerd*) return 0 ;;
        esac
    done
    return 1
}

ss_official_firewall_active() {
    # Official daemon uses STEALTHSURF_* chains (SurfGate uses SSURF_*).
    iptables -w 1 -t filter -nL STEALTHSURF_FWD >/dev/null 2>&1 && return 0
    iptables -w 1 -t filter -nL STEALTHSURF_GRD >/dev/null 2>&1 && return 0
    iptables -w 1 -t mangle -nL STEALTHSURF >/dev/null 2>&1 && return 0
    iptables -w 1 -t nat -nL STEALTHSURF >/dev/null 2>&1 && return 0
    return 1
}

# Strip leftover official jumps/chains after stealthsurf-routerd has stopped.
# Safe only when the process is confirmed down — never touch while it is live.
ss_official_cleanup_orphan_firewall() {
    local ipt tbl ref ch line guard

    ss_official_process_running && return 0
    ss_official_firewall_active || return 0
    command -v iptables >/dev/null 2>&1 || return 0

    if type log_info >/dev/null 2>&1; then
        log_info "Official StealthSurf is stopped — cleaning leftover STEALTHSURF_* firewall chains"
    fi

    for ipt in iptables ip6tables; do
        command -v "$ipt" >/dev/null 2>&1 || continue
        for tbl in filter mangle nat raw; do
            for ref in INPUT FORWARD OUTPUT PREROUTING POSTROUTING; do
                guard=0
                while [ "$guard" -lt 64 ]; do
                    line=$($ipt -w 1 -t "$tbl" -nL "$ref" --line-numbers 2>/dev/null | awk '/STEALTHSURF/ {print $1; exit}')
                    [ -n "$line" ] || break
                    $ipt -w 1 -t "$tbl" -D "$ref" "$line" 2>/dev/null || break
                    guard=$((guard + 1))
                done
            done
            for ch in STEALTHSURF STEALTHSURF_FWD STEALTHSURF_GRD STEALTHSURF_DNS_LOCK \
                STEALTHSURF_DNS_OWNERPROBE STEALTHSURF_DIVERT; do
                $ipt -w 1 -t "$tbl" -F "$ch" 2>/dev/null || true
                $ipt -w 1 -t "$tbl" -X "$ch" 2>/dev/null || true
            done
        done
    done

    return 0
}

ss_official_cache_invalidate() {
    rm -f "$SS_OFFICIAL_CACHE" 2>/dev/null || true
}

ss_official_cache_store() {
    printf '%s %s\n' "$(date +%s 2>/dev/null || echo 0)" "$1" >"$SS_OFFICIAL_CACHE" 2>/dev/null || true
}

ss_official_running() {
    local force="${1:-}" ts status now age running=0

    if [ "$force" != "force" ] && [ -f "$SS_OFFICIAL_CACHE" ]; then
        read -r ts status <"$SS_OFFICIAL_CACHE" 2>/dev/null || true
        now=$(date +%s 2>/dev/null || echo 0)
        if [ -n "$ts" ] && [ -n "$status" ] && [ "$now" -ge "$ts" ] 2>/dev/null; then
            age=$((now - ts))
            if [ "$age" -lt "$SS_OFFICIAL_CACHE_TTL" ] 2>/dev/null; then
                if [ "$status" = "0" ]; then
                    return 1
                fi
                # Positive cache can go stale the moment the user stops official —
                # re-check the live process instead of trusting the cached "1".
                if ss_official_process_running; then
                    return 0
                fi
                # Fall through and recompute (also cleans orphan chains).
            fi
        fi
    fi

    # Only a live stealthsurf-routerd means conflict. Leftover STEALTHSURF_*
    # chains after stop must not keep SurfGate blocked.
    if ss_official_process_running; then
        running=1
    else
        running=0
        ss_official_cleanup_orphan_firewall
    fi

    ss_official_cache_store "$running"
    [ "$running" = "1" ]
}

ss_official_conflict_message() {
    printf '%s\n' "$SS_OFFICIAL_MSG_RU"
}

ss_official_status_json() {
    local installed=false running=false conflict="" msg=""
    ss_official_installed && installed=true
    if ss_official_running; then
        running=true
        conflict="official"
        msg="$SS_OFFICIAL_MSG_RU"
    fi
    jq -nc \
        --argjson installed "$installed" \
        --argjson running "$running" \
        --arg conflict "$conflict" \
        --arg message "$msg" \
        '{
          installed:$installed,
          running:$running,
          conflict:(if $conflict=="" then null else $conflict end),
          message:(if $message=="" then null else $message end)
        }'
}

ss_refuse_if_official() {
    ss_official_cache_invalidate
    if ss_official_running force; then
        log_error "$(ss_official_conflict_message)"
        if type watchdog_clear_desired >/dev/null 2>&1; then
            watchdog_clear_desired 2>/dev/null || true
        fi
        return 1
    fi
    # Ensure orphan official chains are gone before SurfGate brings up SSURF_*.
    ss_official_cleanup_orphan_firewall
    return 0
}

# Combined guard: stock XrayUI or official StealthSurf transparent proxy.
ss_refuse_if_dataplane_conflict() {
    if ! ss_refuse_if_xrayui; then
        return 1
    fi
    if ! ss_refuse_if_official; then
        return 1
    fi
    return 0
}

ss_dataplane_conflict_message() {
    if ss_official_running force 2>/dev/null; then
        ss_official_conflict_message
        return 0
    fi
    if ss_xrayui_running force 2>/dev/null; then
        ss_xrayui_conflict_message
        return 0
    fi
    printf '%s\n' "Конфликт transparent-proxy — остановите другой VPN-аддон, затем запускайте SurfGate."
}
