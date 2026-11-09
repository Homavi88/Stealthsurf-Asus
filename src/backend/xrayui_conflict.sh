#!/bin/sh
# Detect stock XrayUI dataplane conflict.
# Configs/settings are isolated, but two transparent proxies on one LAN break routing.

SS_XRAYUI_PIDFILE="${SS_XRAYUI_PIDFILE:-/var/run/xray.pid}"
SS_XRAYUI_DESIRED="${SS_XRAYUI_DESIRED:-/tmp/xrayui.desired}"
SS_XRAYUI_CONFIG="${SS_XRAYUI_CONFIG:-/opt/etc/xray/config.json}"
SS_XRAYUI_CACHE="${SS_XRAYUI_CACHE:-/tmp/stealthsurf.xrayui.cache}"
SS_XRAYUI_CACHE_TTL="${SS_XRAYUI_CACHE_TTL:-45}"
SS_XRAYUI_MSG_RU="Конфликт с XrayUI — XrayUI сейчас работает. Остановите XrayUI (VPN → XrayUI → Stop), затем запускайте StealthSurf. Одновременно оба аддона нельзя: два transparent-proxy ломают интернет в LAN."

ss_xrayui_installed() {
    [ -x /jffs/scripts/xrayui ] && return 0
    [ -d /opt/share/xrayui ] && return 0
    [ -d /jffs/addons/xrayui ] && return 0
    [ -f /opt/etc/xrayui.conf ] && return 0
    return 1
}

ss_xrayui_pid_alive() {
    local pid="" ours=""
    [ -f "$SS_XRAYUI_PIDFILE" ] || return 1
    pid=$(cat "$SS_XRAYUI_PIDFILE" 2>/dev/null)
    [ -n "$pid" ] || return 1
    if [ -f "$XRAY_PIDFILE" ]; then
        ours=$(cat "$XRAY_PIDFILE" 2>/dev/null)
        [ -n "$ours" ] && [ "$pid" = "$ours" ] && return 1
    fi
    kill -0 "$pid" 2>/dev/null
}

ss_xrayui_process_running() {
    local cfg="$SS_XRAYUI_CONFIG" line="" p cmd
    if command -v ps >/dev/null 2>&1; then
        # shellcheck disable=SC2009
        line=$(ps w 2>/dev/null | grep -E '[x]ray.*(run )?.*(/opt/etc/xray/config\.json|/opt/etc/xray/)' | grep -v stealthsurf | head -1)
        [ -n "$line" ] && return 0
        return 1
    fi
    for p in /proc/[0-9]*; do
        [ -r "$p/cmdline" ] || continue
        cmd=$(tr '\0' ' ' <"$p/cmdline" 2>/dev/null)
        case "$cmd" in
        *xray*"$cfg"* | *xray*/opt/etc/xray/config.json*)
            case "$cmd" in
            *stealthsurf*) continue ;;
            *) return 0 ;;
            esac
            ;;
        esac
    done
    return 1
}

ss_xrayui_firewall_active() {
    iptables -w -t nat -nL XRAYUI >/dev/null 2>&1 && return 0
    iptables -w -t mangle -nL XRAYUI >/dev/null 2>&1 && return 0
    return 1
}

ss_xrayui_cache_invalidate() {
    rm -f "$SS_XRAYUI_CACHE" 2>/dev/null || true
}

ss_xrayui_cache_store() {
    printf '%s %s\n' "$(date +%s 2>/dev/null || echo 0)" "$1" >"$SS_XRAYUI_CACHE" 2>/dev/null || true
}

ss_xrayui_running() {
    local force="${1:-}" ts status now age running=0

    if [ "$force" != "force" ] && [ -f "$SS_XRAYUI_CACHE" ]; then
        read -r ts status <"$SS_XRAYUI_CACHE" 2>/dev/null || true
        now=$(date +%s 2>/dev/null || echo 0)
        if [ -n "$ts" ] && [ -n "$status" ] && [ "$now" -ge "$ts" ] 2>/dev/null; then
            age=$((now - ts))
            if [ "$age" -lt "$SS_XRAYUI_CACHE_TTL" ] 2>/dev/null; then
                [ "$status" = "1" ]
                return $?
            fi
        fi
    fi

    if ss_xrayui_pid_alive; then
        running=1
    elif [ -f "$SS_XRAYUI_DESIRED" ] && ss_xrayui_firewall_active; then
        running=1
    elif ss_xrayui_firewall_active && ss_xrayui_process_running; then
        running=1
    elif ss_xrayui_installed || [ "$force" = "force" ]; then
        if ss_xrayui_process_running; then
            running=1
        fi
    fi

    ss_xrayui_cache_store "$running"
    [ "$running" = "1" ]
}

ss_xrayui_conflict_message() {
    printf '%s\n' "$SS_XRAYUI_MSG_RU"
}

ss_xrayui_status_json() {
    local installed=false running=false conflict="" msg=""
    ss_xrayui_installed && installed=true
    if ss_xrayui_running; then
        running=true
        conflict="xrayui"
        msg="$SS_XRAYUI_MSG_RU"
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

ss_refuse_if_xrayui() {
    ss_xrayui_cache_invalidate
    if ss_xrayui_running force; then
        log_error "$(ss_xrayui_conflict_message)"
        if type watchdog_clear_desired >/dev/null 2>&1; then
            watchdog_clear_desired 2>/dev/null || true
        fi
        return 1
    fi
    return 0
}
