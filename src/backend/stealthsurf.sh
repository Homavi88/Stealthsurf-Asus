#!/bin/sh

import ./_globals.sh
import ./_helper.sh

import ./lock.sh
import ./ntp.sh
import ./config.sh
import ./mount.sh
import ./api.sh
import ./version.sh
import ./control.sh
import ./startup.sh
import ./install.sh
import ./update.sh
import ./firewall.sh
import ./certificates.sh
import ./reality.sh
import ./wireguard.sh
import ./ech.sh
import ./tlsping.sh
import ./general_opts.sh
import ./response.sh
import ./subscriptions.sh
import ./github.sh
import ./geodata.sh
import ./profile.sh
import ./logs.sh
import ./backup.sh
import ./cron.sh
import ./failover.sh
import ./dnsmasq.sh
import ./diagnostics.sh
import ./rtls.sh
import ./b4sni.sh
import ./stealthsurf_api.sh
import ./stealthsurf_api_ops.sh
import ./cli_aliases.sh
import ./xrayui_conflict.sh

# Short CLI (ssurf up|dn|re|st|sy|ls|ap|…) + common long names
ss_cli_dispatch "$@"
_ss_cli_rc=$?
if [ "$_ss_cli_rc" -ne 2 ]; then
    exit "$_ss_cli_rc"
fi

case "$1" in
mount_ui)
    mount_ui
    ;;
unmount_ui)
    unmount_ui
    ;;
remount_ui)
    remount_ui $2
    ;;
dnsmasq)
    dnsmasq_configure "$2"
    ;;
subscriptions)
    case "$2" in
    process)
        process_subscriptions "$3"
        ;;
    esac
    exit 0
    ;;
cron)
    case "$2" in
    logrotate | geodata | subscription_refresh | subscription_fallback | ss_catalog_sync | ipset_save | watchdog)
        cron_job_lock "$2" || exit 0
        update_loading_progress() { :; }
        ;;
    esac
    case "$2" in
    addjobs)
        cron_jobs_add
        ;;
    deletejobs)
        cron_jobs_clear
        ;;
    logrotate)
        cron_logrotate_run
        ;;
    geodata)
        update_community_geodata if_changed
        ;;
    subscription_refresh)
        cron_subscription_refresh_run
        ;;
    subscription_fallback)
        failover_check
        ;;
    ss_catalog_sync)
        cron_ss_catalog_sync_run
        ;;
    watchdog)
        cron_watchdog_run
        ;;
    ipset_save)
        load_xrayui_config
        if [ "$ipsec" = "redirect" ] && [ -n "$(get_xray_daemon_pid)" ] && firewall_is_configured; then
            with_firewall_lock ipset_learned_save
        fi
        ;;
    *) ;;
    esac
    exit $?
    ;;
service_event)
    case "$2" in
    b4sni)
        case "$3" in
        start)
            b4sni_start
            ;;
        stop)
            b4sni_stop
            ;;
        clearlogs)
            b4sni_clear_logs
            ;;
        esac
        ;;
    rtlsscan)
        case "$3" in
        start)
            rtls_scan_start
            ;;
        stop)
            rtls_scan_stop
            ;;
        *) ;;
        esac
        exit 0
        ;;
    startup)
        startup
        ;;
    cleanloadingprogress)
        remove_loading_progress
        ;;
    testconfig)
        test_xray_config true
        ;;
    update)
        # empty payload means "latest"; a payload that fails to load or parse must not fall back to latest
        if ! update_payload=$(reconstruct_payload) || ! update_version=$(printf '%s' "$update_payload" | jq -r '.version // empty' 2>/dev/null); then
            log_error "Could not read the requested update version. Nothing was installed."
            initial_response
            update_loading_progress "Error: could not read the requested version. Nothing was installed." 100
            exit 0
        fi
        if update "${update_version:-latest}"; then
            initial_response
            update_loading_progress "Update process completed!" 100
        else
            initial_response
            update_loading_progress "Error: the update finished with errors. The details are in the system log." 100
        fi
        exit 0
        ;;
    geodata)
        case "$3" in
        communityupdate)
            update_community_geodata
            update_loading_progress "Community geodata files updated successfully." 100
            ;;
        customtagfiles)
            get_custom_geodata_tagfiles
            update_loading_progress "Custom tagfiles retrieved successfully." 100
            ;;
        customrecompileall)
            if geodata_recompile_all; then
                update_loading_progress "Geodata recompiled successfully." 100
            else
                update_loading_progress "Error: geodata could not be recompiled." 100
            fi
            ;;
        customrecompile)
            if geodata_recompile; then
                update_loading_progress "Geodata recompiled successfully." 100
            else
                update_loading_progress "Error: the custom list could not be saved or compiled." 100
            fi
            ;;
        customdeletetag)
            if geodata_delete_tag; then
                update_loading_progress "Geodata tag deleted successfully." 100
            else
                update_loading_progress "Error: the geodata tag could not be deleted or geodata could not be recompiled." 100
            fi
            ;;
        esac
        ;;
    connectedclients)
        api_get_connected_clients
        ;;
    connectionstatus)
        api_get_connection_status
        ;;
    setkey)
        if ss_api_handle_setkey; then
            ss_api_fetch_balances 1 >/dev/null || true
            ss_api_public_keys_view
            update_loading_progress "API key saved." 100
        else
            update_loading_progress "Error: API key rejected." 100
        fi
        ;;
    addkey)
        if ss_api_handle_addkey; then
            ss_api_fetch_balances 1 >/dev/null || true
            ss_api_public_keys_view
            update_loading_progress "API key added." 100
        else
            update_loading_progress "Error: could not add API key." 100
        fi
        ;;
    removekey)
        if ss_api_handle_removekey; then
            ss_api_fetch_balances 1 >/dev/null || true
            ss_api_public_keys_view
            update_loading_progress "API key removed." 100
        else
            update_loading_progress "Error: could not remove API key." 100
        fi
        ;;
    balances | refreshbalances)
        ss_api_fetch_balances 1 >/dev/null || true
        update_loading_progress "Balances refreshed." 100
        ;;
    sync)
        if ss_api_sync_all; then
            ss_api_public_keys_view
            initial_response
            update_loading_progress "StealthSurf catalog synced." 100
        else
            update_loading_progress "Error: sync failed." 100
        fi
        ;;
    importconfigs)
        if ss_api_import_enabled_batch; then
            initial_response
            update_loading_progress "Configs imported into Xray outbounds." 100
        else
            update_loading_progress "Error: import failed." 100
        fi
        ;;
    refreshoutbound | refreshoutbounds)
        if ss_api_refresh_outbound_batch; then
            initial_response
            update_loading_progress "Outbound(s) rebuilt from StealthSurf API." 100
        else
            update_loading_progress "Error: could not refresh outbound from API." 100
        fi
        ;;
    updatesettings)
        if ss_api_handle_update_settings >/dev/null; then
            initial_response
            update_loading_progress "Config settings updated." 100
        else
            update_loading_progress "Error: could not update config settings." 100
        fi
        ;;
    availableservers)
        if ss_api_handle_available_servers >/dev/null; then
            update_loading_progress "Available servers refreshed." 100
        else
            update_loading_progress "Error: could not load available servers." 100
        fi
        ;;
    serverstats)
        if ss_api_handle_server_stats >/dev/null; then
            update_loading_progress "Server stats refreshed." 100
        else
            update_loading_progress "Error: could not load server stats." 100
        fi
        ;;
    traffic)
        if ss_api_handle_traffic >/dev/null; then
            update_loading_progress "Traffic stats refreshed." 100
        else
            update_loading_progress "Error: could not load traffic." 100
        fi
        ;;
    autofit)
        if ss_api_handle_autofit; then
            initial_response
            update_loading_progress "Autofit found a working combination." 100
        else
            initial_response
            update_loading_progress "Autofit finished without a green result." 100
        fi
        ;;
    autorenewal)
        if ss_api_handle_auto_renewal >/dev/null; then
            update_loading_progress "Auto-renewal updated." 100
        else
            update_loading_progress "Error: could not update auto-renewal." 100
        fi
        ;;
    renew)
        if ss_api_handle_renew >/dev/null; then
            update_loading_progress "Renewal requested." 100
        else
            update_loading_progress "Error: renewal failed." 100
        fi
        ;;
    topup)
        if ss_api_handle_topup >/dev/null; then
            update_loading_progress "Top-up requested." 100
        else
            update_loading_progress "Error: top-up failed." 100
        fi
        ;;
    topupcalc)
        if ss_api_handle_topup_calc >/dev/null; then
            update_loading_progress "Top-up options loaded." 100
        else
            update_loading_progress "Error: could not calculate top-up." 100
        fi
        ;;
    regenerate)
        case "$3" in
        realitykeys)
            reality_generate_keys
            ;;
        wgkeys)
            wireguard_generate_keys
            ;;
        sslcertificates)
            regenerate_ssl_certificates
            ;;
        echkeys)
            ech_generate_keys
            ;;
        esac
        ;;
    tlsping)
        tlsping_fetch
        exit 0
        ;;
    configuration)
        case "$3" in
        apply)
            apply_config
            update_loading_progress "Configuration applied successfully." 100
            exit 0
            ;;
        stagechunk)
            stage_chunk
            exit 0
            ;;
        sbscrpts)
            case "$4" in
            fetchprotocols)
                update_loading_progress "Updating subscription protocols..." 0
                if subscription_fetch_protocols; then
                    update_loading_progress "Subscription protocols updated successfully." 100
                else
                    update_loading_progress "No usable links were fetched. The previous list was kept." 100
                fi
                ;;
            esac
            ;;
        logs)
            case "$4" in
            fetch)
                logs_fetch
                ;;
            changeloglevel)
                if change_log_level; then
                    update_loading_progress "Log level changed successfully." 100
                else
                    update_loading_progress "Error: failed to change the log level. Nothing was changed." 100
                fi
                ;;
            *)
                enable_config_logs
                update_loading_progress "Configuration logs enabled successfully." 100
                ;;
            esac
            exit 0
            ;;
        togglestartup)
            toggle_startup
            ;;
        generatedefaultconfig)
            generate_xray_config
            ;;
        initresponse)
            initial_response
            ;;
        applygeneraloptions)
            if apply_general_options; then
                initial_response
                update_loading_progress "General settings applied." 100
            fi
            ;;
        xrayversionswitch)
            switch_stealthsurf_version
            case $? in
            0)
                initial_response
                update_loading_progress "Switched Xray version successfully!" 100
                ;;
            2)
                initial_response
                update_loading_progress "Error: the new Xray version was installed, but Xray did not start with the current configuration. The details are in the system log." 100
                ;;
            *)
                initial_response
                update_loading_progress "Error: failed to switch the Xray version. The details are in the system log." 100
                ;;
            esac
            ;;
        changeprofile)
            change_config_profile
            initial_response
            update_loading_progress "Configuration profile changed successfully." 100
            ;;
        deleteprofile)
            delete_config_profile
            initial_response
            update_loading_progress "Configuration profile deleted successfully." 100
            ;;
        backup)
            backup_configuration
            initial_response
            update_loading_progress "Backup created successfully" 100
            ;;
        backupclear)
            backup_clear
            initial_response
            update_loading_progress "Clearing backup complete." 100
            ;;
        backuprestore)
            backup_restore_configuration
            initial_response
            update_loading_progress "Restore complete." 100
            ;;
        esac
        exit 0
        ;;
    firewall)
        case "$3" in
        configure)
            FIREWALL_FROM_HOOK="true"
            configure_firewall
            ;;
        cleanup)
            cleanup_firewall
            ;;
        esac
        ;;
    serverstatus)
        case "$3" in
        start)
            update_loading_progress "Starting Xray service..." 0
            with_restart_lock start
            case $? in
            0)
                update_loading_progress "Xray service started successfully." 100
                ;;
            "$RESTART_LOCK_BUSY_RC")
                update_loading_progress "Error: another start, stop or restart is still running. Nothing was changed. Try again." 100
                ;;
            *)
                if ss_xrayui_running force 2>/dev/null; then
                    update_loading_progress "$(ss_xrayui_conflict_message)" 100
                else
                    update_loading_progress "Error: Xray did not start. See the system log." 100
                fi
                ;;
            esac
            ;;
        restart)
            update_loading_progress "Restarting Xray service..." 0
            restart
            case $? in
            0)
                update_loading_progress "Xray service restarted successfully." 100
                ;;
            *)
                if ss_xrayui_running force 2>/dev/null; then
                    update_loading_progress "$(ss_xrayui_conflict_message)" 100
                else
                    update_loading_progress "Error: Xray did not restart. See the system log." 100
                fi
                ;;
            esac
            ;;
        stop)
            update_loading_progress "Stopping Xray service..." 0
            with_restart_lock stop
            case $? in
            0)
                update_loading_progress "Xray service stopped successfully." 100
                ;;
            "$RESTART_LOCK_BUSY_RC")
                update_loading_progress "Error: another start, stop or restart is still running. Nothing was changed. Try again." 100
                ;;
            *)
                update_loading_progress "Error: Xray is still running. The details are in the system log." 100
                ;;
            esac
            ;;
        *)
            exit 1
            ;;
        esac
        ;;
    *) ;;
    esac
    exit 0
    ;;
*)
    ss_cli_help
    exit 1
    ;;
esac

exit 0
