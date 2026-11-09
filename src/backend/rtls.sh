#!/bin/sh
# shellcheck disable=SC2034

rtls_scan_start() {
    # Perform the RTLS scan
    log_info "Start RTLS scanning..."
    load_xrayui_config

    local rtls_bin="$ADDON_SHARE_DIR/rtls-scanner"
    local rtlsrequest=$(reconstruct_payload)

    local rtlsipaddr rtlscidr rtls_timeout rtls_threads
    local _rtls_vars
    if ! _rtls_vars=$(echo "$rtlsrequest" | jq -r '
        "rtlsipaddr=" + ((.ip // "") | tostring | @sh) + "\n" +
        "rtlscidr=" + ((.cidr // "") | tostring | @sh) + "\n" +
        "rtls_timeout=" + ((.timeout // "") | tostring | @sh) + "\n" +
        "rtls_threads=" + ((.threads // "") | tostring | @sh)
    '); then
        log_error "Failed to parse RTLS scan parameters."
        return 1
    fi
    eval "$_rtls_vars"

    log_debug "RTLS scan parameters: IP=$rtlsipaddr, CIDR=$rtlscidr, Timeout=$rtls_timeout, Threads=$rtls_threads"

    mkdir -p "$ADDON_SHARE_DIR/logs"
    rm -rf "$ADDON_SHARE_DIR/logs/rtls.log"
    rm -rf "$ADDON_SHARE_DIR/logs/rtls-results.log"

    local rtls_args="-addr $rtlsipaddr$rtlscidr -timeout $rtls_timeout -thread $rtls_threads -out $ADDON_SHARE_DIR/logs/rtls-results.log -mmdb $ADDON_SHARE_DIR/Country.mmdb -cps 200 -fallback -alpn h2"

    $IONICE $NICE "$rtls_bin" $rtls_args >"$ADDON_SHARE_DIR/logs/rtls.log" 2>&1

    log_info "Scanning completed" >>"$ADDON_SHARE_DIR/logs/rtls-results.log"

    log_ok "RTLS scanning completed."
}

rtls_scan_stop() {
    log_info "Stopping RTLS scanning..."
    # Only our binary path — never killall (would hit stock XrayUI's scanner)
    if type ss_kill_by_cmdline_path >/dev/null 2>&1; then
        ss_kill_by_cmdline_path "$ADDON_SHARE_DIR/rtls-scanner"
    else
        local p cmd
        for p in /proc/[0-9]*; do
            [ -r "$p/cmdline" ] || continue
            cmd=$(tr '\0' ' ' <"$p/cmdline" 2>/dev/null)
            case "$cmd" in
            *"$ADDON_SHARE_DIR/rtls-scanner"*) kill "${p##*/}" 2>/dev/null || true ;;
            esac
        done
    fi
    log_ok "RTLS scanning stopped."
}
