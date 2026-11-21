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
SS_OFFICIAL_MSG_RU="Конфликт с официальным StealthSurf — сейчас работает stealthsurf-routerd (файлы могли уже удалить, процесс остался). Остановите: surfgate clear-official — или кнопка в панели. Одновременно оба нельзя: два transparent-proxy ломают интернет в LAN."

ss_official_daemon_path() {
    if [ -n "${OFFICIAL_SS_DAEMON:-}" ]; then
        printf '%s\n' "$OFFICIAL_SS_DAEMON"
        return 0
    fi
    printf '%s\n' "/jffs/addons/stealthsurf/sbin/stealthsurf-routerd"
}

# True only when the official binary is still on disk (empty leftover dirs do not count).
ss_official_daemon_on_disk() {
    local bin
    bin=$(ss_official_daemon_path)
    [ -x "$bin" ] && return 0
    [ -x /jffs/addons/stealthsurf/sbin/stealthsurf-routerd ] && return 0
    return 1
}

ss_official_installed() {
    ss_official_daemon_on_disk && return 0
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

# Collect PIDs of stealthsurf-routerd (space-separated). Empty = none.
ss_official_pids() {
    local p cmd pid out=""
    for p in /proc/[0-9]*; do
        [ -r "$p/cmdline" ] || continue
        cmd=$(tr '\0' ' ' <"$p/cmdline" 2>/dev/null)
        case "$cmd" in
        *stealthsurf-routerd*)
            pid=${p##*/}
            case "$pid" in
            '' | *[!0-9]* | "$$") continue ;;
            esac
            out="$out $pid"
            ;;
        esac
    done
    printf '%s' "${out# }"
}

ss_official_kill_process() {
    local pid i pids
    pids=$(ss_official_pids)
    [ -n "$pids" ] || return 0

    if type log_info >/dev/null 2>&1; then
        log_info "Stopping leftover stealthsurf-routerd (pids:$pids)"
    fi

    for pid in $pids; do
        kill "$pid" 2>/dev/null || true
    done
    i=0
    while [ "$i" -lt 8 ]; do
        ss_official_process_running || return 0
        sleep 1
        i=$((i + 1))
    done

    pids=$(ss_official_pids)
    for pid in $pids; do
        kill -9 "$pid" 2>/dev/null || true
    done
    i=0
    while [ "$i" -lt 5 ]; do
        ss_official_process_running || return 0
        sleep 1
        i=$((i + 1))
    done
    ss_official_process_running && return 1
    return 0
}

# Package deleted (binary gone) but daemon still in RAM — clear so SurfGate can start.
# Returns 0 if no process remains (cleared or was already down); 1 if still running.
ss_official_reap_orphan() {
    ss_official_process_running || {
        ss_official_cleanup_orphan_firewall
        return 0
    }
    if ss_official_daemon_on_disk; then
        # Real install still present — do not kill; SurfGate must refuse.
        return 1
    fi
    if type log_warn >/dev/null 2>&1; then
        log_warn "Official StealthSurf files are gone but stealthsurf-routerd is still running — stopping orphan process"
    fi
    ss_official_kill_process || true
    ss_official_cleanup_orphan_firewall
    ss_official_cache_invalidate
    ss_official_process_running && return 1
    return 0
}

# Force-stop official routerd (files may still exist). Used by CLI / panel clear button.
ss_official_force_stop() {
    ss_official_cache_invalidate
    if ! ss_official_process_running && ! ss_official_firewall_active; then
        if type log_ok >/dev/null 2>&1; then
            log_ok "Official StealthSurf is not running"
        fi
        return 0
    fi
    ss_official_kill_process || true
    ss_official_cleanup_orphan_firewall
    ss_official_cache_invalidate
    if ss_official_process_running; then
        if type log_error >/dev/null 2>&1; then
            log_error "Could not stop stealthsurf-routerd — check: ps w | grep stealthsurf-routerd"
        fi
        return 1
    fi
    if type log_ok >/dev/null 2>&1; then
        log_ok "Official stealthsurf-routerd stopped; SurfGate can start"
    fi
    return 0
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
    # chains after stop must not keep SurfGate blocked. If the user deleted the
    # official package but left the daemon in RAM, reap that orphan instead of
    # blocking SurfGate forever.
    if ss_official_process_running; then
        if ss_official_reap_orphan; then
            running=0
        else
            running=1
        fi
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
