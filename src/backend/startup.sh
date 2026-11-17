#!/bin/sh
# shellcheck disable=SC2034  # codacy:Unused variables

startup() {
    # Use a lock file to prevent concurrent startup executions
    local STARTUP_LOCK="/tmp/stealthsurf_startup.lock"

    # Check if startup is already in progress
    if [ -f "$STARTUP_LOCK" ]; then
        local lock_pid=$(cat "$STARTUP_LOCK" 2>/dev/null)
        if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
            log_warn "Startup already in progress (PID: $lock_pid). Skipping duplicate startup."
            return 0
        fi
        rm -f "$STARTUP_LOCK"
    fi

    echo $$ >"$STARTUP_LOCK"

    trap 'rm -f "$STARTUP_LOCK"' EXIT

    log_ok "Starting $ADDON_TITLE..."

    load_xrayui_config

    cleanup_stale_asdfiles

    local skipwait=${skipwait:-false}
    local startup_delay=${startup_delay:-0}
    remount_ui
    cron_jobs_add

    # Standalone panel (lan_ip or panel_ip :1131) — independent of Merlin ASP UI
    panel_start 2>/dev/null || log_warn "Standalone panel start skipped or failed"

    local xray_pid=$(get_xray_daemon_pid)

    if ss_xrayui_running force 2>/dev/null; then
        log_warn "$(ss_xrayui_conflict_message)"
        watchdog_clear_desired 2>/dev/null || true
        if [ -n "$xray_pid" ]; then
            log_warn "Stopping SurfGate while stock XrayUI is active."
            stop
        fi
    else
        local stealthsurf_startup
        stealthsurf_startup=$(am_settings_get stealthsurf_startup)
        # Empty means never set — match install default (autostart on).
        if [ -z "$stealthsurf_startup" ]; then
            am_settings_set stealthsurf_startup "y"
            stealthsurf_startup="y"
            log_warn "stealthsurf_startup was empty at boot. Defaulting to 'enabled'."
        fi

        if [ "$stealthsurf_startup" = "y" ]; then
            log_ok "Xray service is enabled by SurfGate. Starting Xray service..."

            if [ "$skipwait" = "false" ]; then
                log_ok "Waiting for network and iptable rules to be ready..."
                if [ "$startup_delay" -gt 0 ]; then
                    log_ok "Waiting for $startup_delay seconds before starting Xray service..."
                    sleep "$startup_delay"
                fi
            fi

            rm -f "$STARTUP_LOCK"
            trap - EXIT

            restart
        elif [ -n "$xray_pid" ]; then
            log_ok "Xray service is disabled by SurfGate. Force stopping Xray service..."
            stop
        else
            log_ok "Xray service is disabled by SurfGate. Xray service is not running."
        fi
    fi

    initial_response

    # Remove lock file
    rm -f "$STARTUP_LOCK"
    trap - EXIT
}
