#!/bin/sh
# shellcheck disable=SC2034  # codacy:Unused variables

check_jffs_ready() {

    if [ "$(nvram get jffs2_on 2>/dev/null)" != "1" ]; then
        log_error "JFFS partition is DISABLED (nvram jffs2_on=0)."
        log_error "Enable it under Administration ▸ System, or run:"
        log_error "    nvram set jffs2_on=1 && nvram commit && reboot"
        exit 1
    else
        log_info "JFFS partition is ENABLED."
    fi

    if [ "$(nvram get jffs2_scripts 2>/dev/null)" != "1" ]; then
        log_error "JFFS custom scripts and configs are DISABLED."
        log_error "Enable it in the router UI (Administration ▸ System) or run:"
        log_error "    nvram set jffs2_scripts=1 && nvram commit && reboot"
        exit 1
    else
        log_info "JFFS custom scripts and configs are ENABLED."
    fi
}

install() {

    install_ui_begin "$ADDON_TITLE install" 12
    update_loading_progress "Installing $ADDON_TITLE..." 0
    log_info "Starting $ADDON_TITLE installation process."

    install_ui_step "check JFFS + Entware"
    check_jffs_ready

    load_xrayui_config

    # Check for Entware
    if [ ! -x /opt/bin/opkg ]; then
        install_ui_status fail "Entware missing"
        log_error "Entware is not installed or opkg binary is not accessible."
        log_error "Please install Entware first: https://github.com/Entware/Entware/wiki/Install-on-ASUSWRT"
        exit 1
    fi
    install_ui_status ok "Entware ready"

    install_ui_step "opkg dependencies"
    update_loading_progress "Installing dependencies..."

    opkg update || log_warn "opkg update failed — continuing with cached feeds"
    opkg upgrade || true

    install_opkg_package sed true
    install_opkg_package curl false
    install_opkg_package jq true
    install_opkg_package iptables true
    install_opkg_package net-tools-netstat false
    install_opkg_package libopenssl false
    install_opkg_package flock false
    install_opkg_package logrotate false
    install_opkg_package ipset false
    install_opkg_package findutils false

    if which base64 >/dev/null 2>&1; then
        install_ui_status ok "base64 present"
    else
        install_ui_status run "installing base64"
        install_opkg_package coreutils-base64 false
    fi
    install_ui_status ok "opkg packages"

    install_ui_step "xray-core"
    if which xray >/dev/null 2>&1; then
        install_ui_status ok "xray already installed ($(xray version 2>/dev/null | head -1 | tr -d '\r' || echo ok))"
    else
        # The tested core, not the newest: a newer core may silently ignore settings XRAYUI writes
        install_ui_status run "installing xray-core $XRAYUI_TESTED_CORE"
        if ! switch_stealthsurf_version "$XRAYUI_TESTED_CORE"; then
            log_warn "Could not install xray-core $XRAYUI_TESTED_CORE. Trying the latest release instead..."
            switch_stealthsurf_version "latest"
        fi
        if which xray >/dev/null 2>&1; then
            install_ui_status ok "xray-core installed"
        else
            install_ui_status fail "xray-core missing"
        fi
    fi

    install_ui_step "config + hooks"
    # xrayui config
    if [ ! -f "$XRAYUI_CONFIG_FILE" ]; then

        log_info "XRAYUI config file not found. Creating default config."

        cat <<EOF >"$XRAYUI_CONFIG_FILE"
geoip_url=
geosite_url=
logs_dir=$ADDON_LOGS_DIR
EOF
        chmod 600 "$XRAYUI_CONFIG_FILE"

        install_ui_status ok "default config created"
    else
        install_ui_status ok "config $XRAYUI_CONFIG_FILE"
    fi

    generate_xray_config
    ensure_xray_scaffold
    migrate_homavi88_runtime_to_ssurf 2>/dev/null || true

    clear_script_entries

    # SurfGate hooks only — script is /jffs/scripts/ssurf (never official StealthSurf).
    setup_script_file "/jffs/scripts/nat-start" "$ADDON_SCRIPT service_event firewall configure #ssurf"
    setup_script_file "/jffs/scripts/firewall-start" "$ADDON_SCRIPT service_event firewall configure #ssurf"

    setup_script_file "/jffs/scripts/post-mount" "$ADDON_SCRIPT service_event startup & #ssurf"

    # Merlin action_script names stay stealthsurf_* (Homavi88 panel protocol).
    setup_script_file "/jffs/scripts/service-event" "echo \"\$2\" | grep -q \"^stealthsurf\" && $ADDON_SCRIPT service_event \$(echo \"\$2\" | cut -d'_' -f2- | tr '_' ' ') & #ssurf"

    setup_script_file "/jffs/scripts/dnsmasq.postconf" "$ADDON_SCRIPT dnsmasq \"\$1\" #ssurf"
    # WAN reconnect: rebuild firewall / restart if desired after PPPoE flap
    vpn_wan_hook_install 2>/dev/null || true
    install_ui_status ok "merlin hooks"

    install_ui_step "WebUI mount"
    remount_ui "skipwait"

    am_settings_set stealthsurf_version $XRAYUI_VERSION

    stealthsurf_startup=$(am_settings_get stealthsurf_startup)
    if [ -z "$stealthsurf_startup" ]; then
        am_settings_set stealthsurf_startup "y"
        install_ui_status ok "startup enabled"
    else
        install_ui_status ok "startup already set"
    fi

    mkdir -p $ADDON_USER_SCRIPTS_DIR
    mkdir -p "$ADDON_SHARE_DIR" || log_error "Failed to create $ADDON_SHARE_DIR."
    mkdir -p "$ADDON_TMP_DIR" || log_error "Failed to create $ADDON_TMP_DIR."

    # Companion tools stay upstream (XrayUI releases); only the addon tarball is ours.
    # On package update keep existing binaries — no need to re-fetch every release.
    install_ui_step "module: geodata builder"
    if [ -x "$ADDON_SHARE_DIR/xraydatbuilder" ]; then
        install_ui_status ok "xraydatbuilder (kept)"
    else
        local builder_url="https://github.com/DanielLavrushin/asuswrt-merlin-xrayui/releases/latest/download/xrayui-datbuilder.tar.gz"
        if github_download "$builder_url" "$ADDON_TMP_DIR/xraydatbuilder.tar.gz" 1024 "xraydatbuilder"; then
            if tar -xzf "$ADDON_TMP_DIR/xraydatbuilder.tar.gz" -C "$ADDON_SHARE_DIR"; then
                chmod +x "$ADDON_SHARE_DIR/xraydatbuilder" || true
                install_ui_status ok "xraydatbuilder"
            else
                install_ui_status fail "extract xraydatbuilder"
            fi
            rm -f "$ADDON_TMP_DIR/xraydatbuilder.tar.gz" || true
        else
            install_ui_status skip "geodata builder (custom recompile may be skipped)"
        fi
    fi

    install_ui_step "module: v2dat"
    if [ -x "$ADDON_SHARE_DIR/v2dat" ]; then
        install_ui_status ok "v2dat (kept)"
    else
        local v2dat_arch_name
        v2dat_arch_name=$(version_get_arch_name "v2dat")
        local v2dat_url="https://github.com/DanielLavrushin/v2dat/releases/latest/download/$v2dat_arch_name"
        if github_download "$v2dat_url" "$ADDON_TMP_DIR/v2dat.tar.gz" 1024 "v2dat"; then
            tar -xzf "$ADDON_TMP_DIR/v2dat.tar.gz" -C "$ADDON_SHARE_DIR" || install_ui_status fail "extract v2dat"
            rm -f "$ADDON_TMP_DIR/v2dat.tar.gz" || true
            chmod +x "$ADDON_SHARE_DIR/v2dat" || true
            install_ui_status ok "v2dat"
        else
            install_ui_status fail "v2dat"
        fi
    fi

    install_ui_step "module: rtls-scanner + Country.mmdb"
    if [ -x "$ADDON_SHARE_DIR/rtls-scanner" ]; then
        install_ui_status ok "rtls-scanner (kept)"
    else
        local rtls_arch_name
        rtls_arch_name=$(version_get_arch_name "rtls-scanner")
        local rtls_scan_url="https://github.com/DanielLavrushin/rtls-scanner/releases/latest/download/$rtls_arch_name"
        if github_download "$rtls_scan_url" "$ADDON_TMP_DIR/rtls-scanner.tar.gz" 1024 "rtls-scanner"; then
            tar -xzf "$ADDON_TMP_DIR/rtls-scanner.tar.gz" -C "$ADDON_SHARE_DIR" || install_ui_status fail "extract rtls-scanner"
            rm -f "$ADDON_TMP_DIR/rtls-scanner.tar.gz" || true
            chmod +x "$ADDON_SHARE_DIR/rtls-scanner" || true
            install_ui_status ok "rtls-scanner"
        else
            install_ui_status fail "rtls-scanner"
        fi
    fi
    local mmdb_sz=0
    [ -f "$ADDON_SHARE_DIR/Country.mmdb" ] && mmdb_sz=$(wc -c <"$ADDON_SHARE_DIR/Country.mmdb" | tr -d ' ')
    case "$mmdb_sz" in '' | *[!0-9]*) mmdb_sz=0 ;; esac
    if [ "$mmdb_sz" -ge 102400 ]; then
        install_ui_status ok "Country.mmdb (kept)"
    else
        local mmdb_url="https://github.com/Loyalsoldier/geoip/releases/latest/download/Country.mmdb"
        if github_download "$mmdb_url" "$ADDON_SHARE_DIR/Country.mmdb" 102400 "Country.mmdb"; then
            install_ui_status ok "Country.mmdb"
        else
            install_ui_status skip "Country.mmdb"
        fi
    fi

    install_ui_step "module: b4sni"
    if [ -x "$ADDON_SHARE_DIR/b4sni" ]; then
        install_ui_status ok "b4sni (kept)"
    else
        local b4sni_arch_name
        b4sni_arch_name=$(version_get_arch_name "b4sni" "linux")
        local b4sni_url="https://github.com/DanielLavrushin/b4sni/releases/latest/download/$b4sni_arch_name"
        if github_download "$b4sni_url" "$ADDON_TMP_DIR/b4sni.tar.gz" 1024 "b4sni"; then
            tar -xzf "$ADDON_TMP_DIR/b4sni.tar.gz" -C "$ADDON_SHARE_DIR" || install_ui_status fail "extract b4sni"
            rm -f "$ADDON_TMP_DIR/b4sni.tar.gz" || true
            chmod +x "$ADDON_SHARE_DIR/b4sni" || true
            install_ui_status ok "b4sni"
        else
            install_ui_status fail "b4sni ($b4sni_arch_name)"
        fi
    fi

    mkdir -p "$XRAY_CONFIG_DIR" "$ADDON_SHARE_DIR/data" 2>/dev/null
    # Isolate from stock XrayUI: never use /opt/etc/xray/config.json as our profile.
    # Repair NUL/corrupt JSON BEFORE logrotate/jq — otherwise update prints
    # "jq: parse error" and "Could not update …; it was left unchanged."
    load_xrayui_config
    ensure_xray_scaffold
    if xray_config_is_valid "$XRAY_CONFIG_FILE"; then
        install_ui_status ok "config $XRAY_CONFIG_FILE"
    else
        install_ui_status fail "config $XRAY_CONFIG_FILE still invalid"
        log_warn "Xray config could not be repaired; continuing install with defaults where possible"
    fi

    install_ui_step "logrotate + cron"
    logrotate_setup
    cron_jobs_add
    install_ui_status ok "cron jobs"

    # Move junk out of geodata data/ (outbound-ss-* caused invalid attribute errors)
    geodata_sanitize_datadir 2>/dev/null || true

    # Package update re-runs install — do not re-download multi‑MB geosite/geoip
    # when they already sit next to xray (shared with stock XrayUI). Force refresh
    # still available via panel / cron (update_community_geodata / if_changed).
    install_ui_step "geosite.dat + geoip.dat"
    if update_community_geodata skip_if_present; then
        install_ui_status ok "community geodata"
    else
        install_ui_status skip "community geodata (will retry later via cron / panel)"
        log_warn "Community geodata update finished with warnings"
    fi

    cleanup_stale_asdfiles

    if xray_config_is_valid "$XRAY_CONFIG_FILE"; then
        log_info "Updating $XRAY_CONFIG_FILE config to version 0.55.1..."
        jq_update_file "$XRAY_CONFIG_FILE" '
          if .inbounds then .inbounds |= map(select(.tag != "sys:socks-in")) else . end
        | .routing.rules //= []
        | .routing.rules |= map(select(.name != "sys:connection-check"))
      ' || log_warn "Could not update $XRAY_CONFIG_FILE; it was left unchanged."
    else
        log_warn "Skipping config migration — $XRAY_CONFIG_FILE is not valid JSON"
    fi

    xrayui_core_forget
    xrayui_core_probe
    if [ -z "$(xrayui_core_version)" ]; then
        install_ui_status fail "xray core unavailable"
        log_error_box "Installation finished, but the Xray core is not available ($XRAYUI_CORE_ERR). Install it with: surfgate update xray $XRAYUI_TESTED_CORE"
        update_loading_progress "Installation finished, but the Xray core is not available."
        return 1
    fi
    install_ui_status ok "xray core $(xrayui_core_version)"

    # StealthSurf API caches + migrate keys from 1.0.x addon conf
    ss_api_ensure_caches 2>/dev/null || true
    ss_api_migrate_legacy_keys 2>/dev/null || true
    ss_api_public_keys_view 2>/dev/null || true
    ss_cli_ensure_bin_links 2>/dev/null || {
        ln -sf "$ADDON_SCRIPT" /opt/bin/surfgate 2>/dev/null || true
        ln -sf "$ADDON_SCRIPT" /opt/bin/ssurf 2>/dev/null || true
        ln -sf "$ADDON_SCRIPT" /opt/bin/ss 2>/dev/null || true
        rm -f /opt/bin/stealthsurf 2>/dev/null || true
    }
    # Clear legacy 1.0.x service-event block if present (replaced by #stealthsurf hook)
    if [ -f /jffs/scripts/service-event ] && grep -qE 'StealthSurf UI hook|SurfGate UI hook' /jffs/scripts/service-event 2>/dev/null; then
        awk '
          /StealthSurf UI hook begin|SurfGate UI hook begin/ {skip=1; next}
          skip && (/StealthSurf UI hook end/ || /SurfGate UI hook end/) {skip=0; next}
          skip {next}
          {print}
        ' /jffs/scripts/service-event >/tmp/stealthsurf_se.$$ && mv /tmp/stealthsurf_se.$$ /jffs/scripts/service-event
        chmod 0755 /jffs/scripts/service-event 2>/dev/null || true
    fi

    install_ui_step "panel :1131"
    # Standalone panel on :1131 — no interaction with official StealthSurf (:8800).
    if [ ! -f "$ADDON_JFFS_ADN_DIR/panel/index.html" ] && [ -f "$ADDON_JFFS_ADN_DIR/index.panel.html" ]; then
        mkdir -p "$ADDON_JFFS_ADN_DIR/panel"
        cp -f "$ADDON_JFFS_ADN_DIR/index.panel.html" "$ADDON_JFFS_ADN_DIR/panel/index.html"
    fi
    panel_prepare_webroot 2>/dev/null || true
    # Prefer bundled panel-httpd from the package (works even when opkg feeds are down).
    panel_ensure_httpd 2>/dev/null || true

    local _panel_url
    _panel_url=$(panel_url 2>/dev/null || echo "http://$(nvram get lan_ipaddr 2>/dev/null):1131/")

    # Tell the UI we're done BEFORE restarting httpd. Self-update polls
    # /ext/ssurf/xray-ui-response through the panel; panel_stop would otherwise
    # make those polls fail and the update modal show a false error.
    update_loading_progress "Installation completed. Panel: $_panel_url" 100
    sleep 2

    # Always restart so an upgraded panel-httpd replaces the stale process (avoids bootstrap HTTP 500).
    panel_stop 2>/dev/null || true
    if ! panel_start; then
        install_ui_status fail "panel httpd"
        log_warn "Standalone panel did not start. See /tmp/ssurf/panel.log"
        log_warn "Fix: surfgate panel restart   (1.4.11+ ships bin/panel-httpd; or install lighttpd via opkg)"
    else
        install_ui_status ok "panel httpd"
    fi

    install_ui_end "Installed $(show_version) → $_panel_url"
    log_ok "Installed $(show_version) (files in $ADDON_JFFS_ADN_DIR, panel :1131)"
    log_box "Installation completed. Open panel: $_panel_url"
    log_info "Merlin WebUI: VPN → $ADDON_TITLE  ·  CLI: surfgate panel status"
    log_info "Official StealthSurf path /jffs/addons/stealthsurf is never modified by SurfGate."
}

uninstall() {
    log_info "Starting XRAY UI uninstallation process."

    panel_stop 2>/dev/null || true
    panel_remove_secondary_ip 2>/dev/null || true

    # Stop XRAY service if running
    if [ -f "$XRAY_PIDFILE" ]; then
        log_info "Stopping XRAY service..."
        stop
        rm -f $XRAY_PIDFILE
        log_info "XRAY service stopped."
    else
        log_warn "XRAY service is not running."
    fi

    # Clear fail-closed service lock left armed by stop()
    vpn_service_lock_clear 2>/dev/null || true
    split_lock_domains=""
    if type dnsmasq_strip_addon_block >/dev/null 2>&1; then
        dnsmasq_strip_addon_block /etc/dnsmasq.conf 2>/dev/null || true
    fi
    for set in "${IPSET_LOCK_V4:-}" "${IPSET_LOCK_V6:-}"; do
        [ -n "$set" ] || continue
        ipset list -n 2>/dev/null | grep -qx "$set" && ipset destroy "$set" 2>/dev/null || true
    done

    # Remove our files only — never /jffs/addons/stealthsurf when official VPN is there
    log_info "Removing XRAY UI files from $ADDON_JFFS_ADN_DIR..."
    rm -rf "$ADDON_WEB_DIR" || log_warn "Failed to remove $ADDON_WEB_DIR."
    rm -rf "$ADDON_JFFS_ADN_DIR" || log_warn "Failed to remove $ADDON_JFFS_ADN_DIR."
    # Never read/write/delete under /jffs/addons/stealthsurf (official StealthSurf).
    rm -rf "$ADDON_SHARE_DIR"/*.json || log_warn "Failed to remove $ADDON_SHARE_DIR/*.json."
    rm -rf "$ADDON_SHARE_DIR/logs" || log_warn "Failed to remove $ADDON_SHARE_DIR/logs."

    rm -rf "$ADDON_SHARE_DIR/rtls-scanner" || log_warn "Failed to remove $ADDON_SHARE_DIR/rtls-scanner."
    rm -rf "$ADDON_SHARE_DIR/v2dat" || log_warn "Failed to remove $ADDON_SHARE_DIR/v2dat."

    rm -rf "$ADDON_SHARE_DIR/Country.mmdb" || log_warn "Failed to remove $ADDON_SHARE_DIR/Country.mmdb."

    rm -rf "$ADDON_SHARE_DIR/dnsmasq" || log_warn "Failed to remove $ADDON_SHARE_DIR/dnsmasq."
    rm -rf "$ADDON_SHARE_DIR/tmp" || log_warn "Failed to remove $ADDON_SHARE_DIR/tmp."

    if [ $? -eq 0 ]; then
        log_info "XRAY UI files removed successfully."
    else
        log_error "Failed to remove XRAY UI files."
        exit 1
    fi

    clear_script_entries

    # Unmount UI
    log_info "Unmounting XRAY UI..."
    unmount_ui

    if [ $? -eq 0 ]; then
        log_info "XRAY UI unmounted successfully."
    else
        log_error "Failed to unmount XRAY UI."
        exit 1
    fi

    # Remove XRAY custom settings
    log_info "Removing XRAY custom settings..."

    # Only our keys — never delete stock XrayUI xray_* settings
    grep '^stealthsurf_' /jffs/addons/custom_settings.txt 2>/dev/null | while IFS='=' read -r var_name _; do
        [ -n "$var_name" ] && am_settings_del "$var_name"
    done

    log_info "Custom settings removed successfully."

    # Remove XRAY UI shared files
    log_info "Removing XRAY UI geodata files builder..."
    rm -rf "$ADDON_SHARE_DIR/xraydatbuilder" || log_debug "Failed to remove $ADDON_SHARE_DIR/xraydatbuilder."

    # Detect stock XrayUI so we never delete its shared resources
    local stock_xrayui=false
    if type ss_xrayui_installed >/dev/null 2>&1 && ss_xrayui_installed; then
        stock_xrayui=true
        log_info "Stock XrayUI detected — shared Xray/geodata/xrayui.conf will be preserved."
    fi

    echo
    log_warn "Do you want to remove SurfGate custom GEODATA? (yes/no)"
    read -r user_input

    if [ "$user_input" = "yes" ] || [ "$user_input" = "y" ]; then
        log_info "Removing SurfGate custom GEODATA..."
        rm -rf "$ADDON_SHARE_DIR" || log_debug "Failed to remove $ADDON_SHARE_DIR."
        # Only our custom dat helper — never /opt/sbin/xrayui (stock XrayUI)
        # Our custom dat name is ssurf; also drop legacy Homavi88 /opt/sbin/stealthsurf
        rm -f /opt/sbin/ssurf /opt/sbin/stealthsurf || log_debug "Failed to remove SurfGate custom geodata helper."
        if [ "$stock_xrayui" = "true" ]; then
            log_info "Keeping shared community geodata (geoip.dat/geosite.dat) for stock XrayUI."
        else
            rm -f /opt/sbin/geosite.dat /opt/sbin/geoip.dat || log_debug "Failed to remove community geodata."
        fi
    else
        log_info "Keeping custom GEODATA."
    fi
    user_input=""

    # Ask user if they want to remove backups
    echo
    log_warn "Do you want to remove SurfGate BACKUPS? (yes/no)"
    read -r user_input

    if [ "$user_input" = "yes" ] || [ "$user_input" = "y" ]; then
        log_info "Removing SurfGate BACKUPS..."
        backup_clear
    else
        log_info "Keeping SurfGate BACKUPS."
    fi
    user_input=""

    # Profile tree is always ours — safe even when XrayUI is installed
    if [ -d "$XRAY_CONFIG_DIR" ]; then
        log_info "Removing SurfGate profile tree $XRAY_CONFIG_DIR..."
        rm -rf "$XRAY_CONFIG_DIR" || log_debug "Failed to remove $XRAY_CONFIG_DIR."
    fi

    if [ "$stock_xrayui" = "true" ]; then
        log_info "Keeping shared /opt/sbin/xray and /opt/etc/xray (stock XrayUI still needs them)."
    else
        echo
        log_warn "Do you want to remove XRAY core (/opt/sbin/xray) and remaining /opt/etc/xray? (yes/no)"
        read -r user_input

        if [ "$user_input" = "yes" ] || [ "$user_input" = "y" ]; then
            if opkg list-installed 2>/dev/null | grep -q '^xray$'; then
                log_info "Removing XRAY from Entware..."
                if opkg remove xray; then
                    log_info "XRAY removed successfully."
                else
                    log_error "Failed to remove XRAY."
                    exit 1
                fi
            else
                log_info "XRAY is not installed via opkg."
            fi

            rm -f /opt/sbin/xray /opt/sbin/geoip.dat /opt/sbin/geosite.dat || log_debug "Failed to remove xray binaries/geodata."
            # Only remove remaining tree if empty of stock files; never if config.json exists
            if [ -f /opt/etc/xray/config.json ]; then
                log_warn "Keeping /opt/etc/xray because stock config.json is present."
            else
                log_info "Removing remaining XRAY configuration under /opt/etc/xray..."
                rm -rf /opt/etc/xray || log_debug "Failed to remove /opt/etc/xray."
            fi
        else
            log_info "Keeping XRAY and its configuration files."
        fi
        user_input=""
    fi

    echo
    log_warn "Do you want to remove SurfGate settings ($XRAYUI_CONFIG_FILE)? (yes/no)"
    read -r user_input
    if [ "$user_input" = "yes" ] || [ "$user_input" = "y" ]; then
        log_info "Removing SurfGate settings..."
        # Never delete stock /opt/etc/xrayui.conf or official addon state
        rm -f "$XRAYUI_CONFIG_FILE" || log_debug "Failed to remove settings conf."
        # Drop legacy Homavi88 conf only when it looks like ours
        if [ -f /opt/etc/stealthsurf.conf ] && grep -qE 'panel_|ss_api|ADDON_|stlth_|geoip_url' /opt/etc/stealthsurf.conf 2>/dev/null; then
            rm -f /opt/etc/stealthsurf.conf || true
        fi
    else
        log_info "Keeping SurfGate settings ($XRAYUI_CONFIG_FILE)."
    fi

    # Strip leftover dnsmasq hijack before hooks are gone
    if type dnsmasq_strip_addon_block >/dev/null 2>&1; then
        dnsmasq_strip_addon_block /etc/dnsmasq.conf
    fi
    if type logs_scribe_remove >/dev/null 2>&1; then
        logs_scribe_remove
    else
        rm -f "/opt/etc/syslog-ng.d/${ADDON_TAG}" 2>/dev/null
    fi

    cron_jobs_clear

    # Only our logrotate stanza — never stock xrayui
    rm -f /opt/etc/logrotate.d/ssurf /opt/etc/logrotate.d/stealthsurf || log_debug "Failed to remove logrotate config."
    rm -f /opt/bin/surfgate /opt/bin/ssurf /opt/bin/ss 2>/dev/null
    # Never create/claim /opt/bin/stealthsurf; remove only if it pointed at our script
    if [ -L /opt/bin/stealthsurf ]; then
        case "$(readlink /opt/bin/stealthsurf 2>/dev/null)" in
        /jffs/scripts/ssurf | /jffs/scripts/stealthsurf | */addons/ssurf/*)
            rm -f /opt/bin/stealthsurf 2>/dev/null || true
            ;;
        esac
    fi
    rm -f /jffs/scripts/ssurf 2>/dev/null || true
    # Remove legacy Homavi88 script path only when fingerprint matches (never official)
    if [ -f /jffs/scripts/stealthsurf ] &&
        grep -q 'ADDON_TITLE="SurfGate"\|ADDON_PKG_NAME="ssurf"\|Homavi88' /jffs/scripts/stealthsurf 2>/dev/null; then
        rm -f /jffs/scripts/stealthsurf 2>/dev/null || true
    fi
    # Never remove /jffs/addons/stealthsurf (official StealthSurf).

    log_box "Uninstallation process completed successfully."
}

install_opkg_package() {
    local package="$1"
    local critical=$2
    # Check for jq
    if ! opkg list-installed | grep "$package -"; then
        install_ui_status run "opkg install $package"
        if opkg install $package; then
            install_ui_status ok "opkg $package"
        else
            if [ "$critical" = true ]; then
                install_ui_status fail "opkg $package (critical)"
                log_error "Critical package $package failed to install. Exiting."
                exit 1
            else
                install_ui_status skip "opkg $package"
                log_warn "Non-critical package $package failed to install. Continuing."
            fi
        fi
    else
        install_ui_status ok "opkg $package (cached)"
    fi
}

setup_script_file() {

    local script_file="$1"
    local command_entry="$2"

    log_debug "Scritpt file: $script_file"
    log_debug "Command entry: $command_entry"

    if [ ! -f "$script_file" ]; then
        printf '#!/bin/sh\n\n' >"$script_file"
    else
        if ! head -n1 "$script_file" | grep -qx '#!/bin/sh'; then
            log_error "$script_file is missing the she-bang (#!/bin/sh)"
        fi
    fi

    if ! grep -Fqx -- "$command_entry" "$script_file"; then
        echo "$command_entry" >>"$script_file" || {
            log_error "Failed to add command entry to $script_file"
            return 1
        }
    fi

    chmod +x "$script_file"
    log_info "Updated $script_file with $ADDON_TITLE command entry."
}

clear_script_entries() {

    log_info "Removing existing $ADDON_TITLE entries from scripts."
    sed '/#ssurf/d;/#stealthsurf/d' /jffs/scripts/services-start >/tmp/stealthsurf_hook.$$ 2>/dev/null && mv /tmp/stealthsurf_hook.$$ /jffs/scripts/services-start && chmod +x /jffs/scripts/services-start || log_debug "Failed to remove entry from /jffs/scripts/services-start."
    sed '/#ssurf/d;/#stealthsurf/d' /jffs/scripts/nat-start >/tmp/stealthsurf_hook.$$ 2>/dev/null && mv /tmp/stealthsurf_hook.$$ /jffs/scripts/nat-start && chmod +x /jffs/scripts/nat-start || log_debug "Failed to remove entry from /jffs/scripts/nat-start."
    sed '/#ssurf/d;/#stealthsurf/d' /jffs/scripts/firewall-start >/tmp/stealthsurf_hook.$$ 2>/dev/null && mv /tmp/stealthsurf_hook.$$ /jffs/scripts/firewall-start && chmod +x /jffs/scripts/firewall-start || log_debug "Failed to remove entry from /jffs/scripts/firewall-start."
    sed '/#ssurf/d;/#stealthsurf/d' /jffs/scripts/post-mount >/tmp/stealthsurf_hook.$$ 2>/dev/null && mv /tmp/stealthsurf_hook.$$ /jffs/scripts/post-mount && chmod +x /jffs/scripts/post-mount || log_debug "Failed to remove entry from /jffs/scripts/post-mount."
    sed '/#ssurf/d;/#stealthsurf/d' /jffs/scripts/service-event >/tmp/stealthsurf_hook.$$ 2>/dev/null && mv /tmp/stealthsurf_hook.$$ /jffs/scripts/service-event && chmod +x /jffs/scripts/service-event || log_debug "Failed to remove entry from /jffs/scripts/service-event."
    sed '/#ssurf/d;/#stealthsurf/d' /jffs/scripts/dnsmasq.postconf >/tmp/stealthsurf_hook.$$ 2>/dev/null && mv /tmp/stealthsurf_hook.$$ /jffs/scripts/dnsmasq.postconf && chmod +x /jffs/scripts/dnsmasq.postconf || log_debug "Failed to remove entry from /jffs/scripts/dnsmasq.postconf."
    sed '/#ssurf/d;/#stealthsurf/d' /jffs/scripts/wan-start >/tmp/stealthsurf_hook.$$ 2>/dev/null && mv /tmp/stealthsurf_hook.$$ /jffs/scripts/wan-start && chmod +x /jffs/scripts/wan-start || log_debug "Failed to remove entry from /jffs/scripts/wan-start."
    sed '/#ssurf/d;/#stealthsurf/d' /jffs/scripts/wan-event >/tmp/stealthsurf_hook.$$ 2>/dev/null && mv /tmp/stealthsurf_hook.$$ /jffs/scripts/wan-event && chmod +x /jffs/scripts/wan-event || log_debug "Failed to remove entry from /jffs/scripts/wan-event."
}
