#!/bin/sh
# Detect official StealthSurf VPN (stealthsurf-routerd) dataplane conflict.
# Paths/settings are isolated under /jffs/addons/ssurf, but two transparent
# proxies on one LAN break routing — refuse SurfGate start while official runs.
#
# Hard rules (1.4.44+):
# - Status / panel polls are SIDE-EFFECT FREE: never kill, never flush STEALTHSURF_*.
# - Auto-cleanup of STEALTHSURF_* only when the official package is NOT installed
#   (true orphans after delete) or the user force-clears / SurfGate is about to start
#   and the process is confirmed down.
# - Never treat a live install as an "orphan" just because the binary path moved.

SS_OFFICIAL_CACHE="${SS_OFFICIAL_CACHE:-/tmp/stealthsurf.official.cache}"
SS_OFFICIAL_CACHE_TTL="${SS_OFFICIAL_CACHE_TTL:-15}"
SS_OFFICIAL_MSG_RU="Конфликт с официальным StealthSurf — сейчас работает stealthsurf-routerd. Остановите official VPN (панель :8800) или: surfgate clear-official. Одновременно оба нельзя: два transparent-proxy ломают интернет в LAN."

ss_official_daemon_path() {
    if [ -n "${OFFICIAL_SS_DAEMON:-}" ]; then
        printf '%s\n' "$OFFICIAL_SS_DAEMON"
        return 0
    fi
    printf '%s\n' "/jffs/addons/stealthsurf/sbin/stealthsurf-routerd"
}

ss_official_jffs_dir() {
    if [ -n "${OFFICIAL_SS_JFFS_DIR:-}" ]; then
        printf '%s\n' "$OFFICIAL_SS_JFFS_DIR"
        return 0
    fi
    printf '%s\n' "/jffs/addons/stealthsurf"
}

# True when the official package still looks installed (not just an empty leftover dir).
ss_official_daemon_on_disk() {
    local bin dir
    bin=$(ss_official_daemon_path)
    [ -x "$bin" ] && return 0
    [ -x /jffs/addons/stealthsurf/sbin/stealthsurf-routerd ] && return 0
    [ -x /jffs/addons/stealthsurf/bin/stealthsurf-routerd ] && return 0
    [ -f /jffs/addons/stealthsurf/sbin/stealthsurf-routerd ] && return 0
    [ -f /jffs/addons/stealthsurf/bin/stealthsurf-routerd ] && return 0
    dir=$(ss_official_jffs_dir)
    # Any real package marker under the official tree — do NOT treat as deleted.
    [ -f "$dir/version" ] && return 0
    [ -f "$dir/www/index.html" ] && return 0
    [ -f "$dir/scripts/stealthsurf" ] && return 0
    [ -f "$dir/stealthsurf" ] && return 0
    [ -d "$dir/sbin" ] && [ -n "$(ls -A "$dir/sbin" 2>/dev/null)" ] && return 0
    return 1
}

ss_official_installed() {
    ss_official_daemon_on_disk && return 0
    return 1
}

# Live process — BusyBox-friendly. Prefer pidof, then /proc, then ps.
ss_official_process_running() {
    local line="" p cmd
    if command -v pidof >/dev/null 2>&1; then
        pidof stealthsurf-routerd >/dev/null 2>&1 && return 0
    fi
    for p in /proc/[0-9]*; do
        [ -r "$p/cmdline" ] || continue
        cmd=$(tr '\0' ' ' <"$p/cmdline" 2>/dev/null)
        case "$cmd" in
        *stealthsurf-routerd*) return 0 ;;
        esac
        # Some builds launch via a short name / symlink basename only.
        if [ -r "$p/comm" ]; then
            case "$(cat "$p/comm" 2>/dev/null)" in
            stealthsurf-routerd | stealthsurf-route) return 0 ;;
            esac
        fi
    done
    if command -v ps >/dev/null 2>&1; then
        # shellcheck disable=SC2009
        line=$(ps w 2>/dev/null | grep '[s]tealthsurf-routerd' | head -1)
        [ -n "$line" ] && return 0
    fi
    return 1
}

# Official panel listens on :8800 — strong secondary signal when process name is odd.
ss_official_port_listening() {
    local p
    # /proc/net/tcp: port 8800 = 0x2260
    if [ -r /proc/net/tcp ]; then
        awk 'NR>1 { split($2,a,":"); if (toupper(a[2])=="2260") found=1 }
             END { exit(found?0:1) }' /proc/net/tcp 2>/dev/null && return 0
    fi
    if command -v netstat >/dev/null 2>&1; then
        netstat -lnt 2>/dev/null | grep -qE '[:.]8800[[:space:]]' && return 0
    fi
    if command -v ss >/dev/null 2>&1; then
        ss -lnt 2>/dev/null | grep -qE '[:.]8800[[:space:]]' && return 0
    fi
    # Last resort: anything holding 8800 in /proc (cheap fd scan is too heavy — skip).
    return 1
}

# Collect PIDs of stealthsurf-routerd (space-separated). Empty = none.
ss_official_pids() {
    local p cmd pid out=""
    if command -v pidof >/dev/null 2>&1; then
        out=$(pidof stealthsurf-routerd 2>/dev/null | tr ' ' '\n' | tr '\n' ' ')
        out=$(printf '%s' "$out" | sed 's/[[:space:]]*$//')
        [ -n "$out" ] && {
            printf '%s' "$out"
            return 0
        }
    fi
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

# Package deleted (binary/tree gone) but daemon still in RAM — clear so SurfGate can start.
# Returns 0 if no process remains (cleared or was already down); 1 if still running.
# NEVER kills when the official package is still on disk.
ss_official_reap_orphan() {
    ss_official_process_running || {
        # Only scrub firewall when the package is gone — leave a stopped install alone.
        if ! ss_official_daemon_on_disk; then
            ss_official_cleanup_orphan_firewall
        fi
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
    if ! ss_official_process_running && ! ss_official_firewall_active && ! ss_official_port_listening; then
        if type log_ok >/dev/null 2>&1; then
            log_ok "Official StealthSurf is not running"
        fi
        return 0
    fi
    ss_official_kill_process || true
    # Force path: user asked to clear — scrub chains even if package remains.
    ss_official_cleanup_orphan_firewall force
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
    command -v iptables >/dev/null 2>&1 || return 1
    iptables -w 1 -t filter -nL STEALTHSURF_FWD >/dev/null 2>&1 && return 0
    iptables -w 1 -t filter -nL STEALTHSURF_GRD >/dev/null 2>&1 && return 0
    iptables -w 1 -t mangle -nL STEALTHSURF >/dev/null 2>&1 && return 0
    iptables -w 1 -t nat -nL STEALTHSURF >/dev/null 2>&1 && return 0
    return 1
}

# Strip leftover official jumps/chains.
# Default: only when process is down AND official package is NOT installed.
# Pass "force" to scrub after clear-official / before SurfGate start (process must still be down).
ss_official_cleanup_orphan_firewall() {
    local ipt tbl ref ch line guard mode="${1:-}"

    ss_official_process_running && return 0
    ss_official_firewall_active || return 0
    command -v iptables >/dev/null 2>&1 || return 0

    if [ "$mode" != "force" ] && ss_official_daemon_on_disk; then
        # Package still installed — leave its chains alone (official may be stopped
        # between starts; wiping them makes the official app glitch).
        return 0
    fi

    if type log_info >/dev/null 2>&1; then
        log_info "Cleaning leftover STEALTHSURF_* firewall chains (official process down)"
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

# Pure detection — NO kill / NO iptables flush. Safe for Home status polls.
ss_official_running() {
    local force="${1:-}" ts status now age

    if [ "$force" != "force" ] && [ -f "$SS_OFFICIAL_CACHE" ]; then
        read -r ts status <"$SS_OFFICIAL_CACHE" 2>/dev/null || true
        now=$(date +%s 2>/dev/null || echo 0)
        if [ -n "$ts" ] && [ -n "$status" ] && [ "$now" -ge "$ts" ] 2>/dev/null; then
            age=$((now - ts))
            if [ "$age" -lt "$SS_OFFICIAL_CACHE_TTL" ] 2>/dev/null; then
                # Always re-check live signals — both positive and negative cache go stale
                # when the user starts/stops official (Home polls every ~2s).
                if ss_official_live_signal; then
                    ss_official_cache_store 1
                    return 0
                fi
                ss_official_cache_store 0
                return 1
            fi
        fi
    fi

    if ss_official_live_signal; then
        ss_official_cache_store 1
        return 0
    fi
    ss_official_cache_store 0
    return 1
}

# True when official dataplane / control plane is live.
ss_official_live_signal() {
    ss_official_process_running && return 0
    ss_official_port_listening && return 0
    return 1
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
        # If files were deleted but process remains, try one orphan reap then re-check.
        if ! ss_official_daemon_on_disk; then
            ss_official_reap_orphan || true
            ss_official_cache_invalidate
            if ! ss_official_running force; then
                ss_official_cleanup_orphan_firewall force
                return 0
            fi
        fi
        log_error "$(ss_official_conflict_message)"
        if type watchdog_clear_desired >/dev/null 2>&1; then
            watchdog_clear_desired 2>/dev/null || true
        fi
        return 1
    fi
    # Official not live — scrub orphan chains only if package is gone, else force-clean
    # so SurfGate can bring up SSURF_* without fighting leftover jumps.
    if ss_official_daemon_on_disk; then
        ss_official_cleanup_orphan_firewall force
    else
        ss_official_cleanup_orphan_firewall
    fi
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
