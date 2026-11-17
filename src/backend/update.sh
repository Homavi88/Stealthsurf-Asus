#!/bin/sh
# shellcheck disable=SC2034  # codacy:Unused variables

update() {

    update_loading_progress "Updating $ADDON_TITLE..." 0

    local specific_version=${1:-"latest"}
    specific_version=${specific_version#v}

    # reject anything outside the tag alphabet first: grep matches per line, so a newline would slip through
    case "$specific_version" in
    *[!0-9A-Za-z.-]*)
        log_error "Invalid version requested: $specific_version"
        return 1
        ;;
    esac

    if [ "$specific_version" != "latest" ] && ! printf '%s\n' "$specific_version" | grep -Eq '^[0-9]+\.[0-9]+(\.[0-9]+)?([.-]?[A-Za-z0-9]+)*$'; then
        log_error "Invalid version requested: $specific_version"
        return 1
    fi

    local asset="asuswrt-merlin-surfgate.tar.gz"
    local asset_legacy="asuswrt-merlin-stealthsurf.tar.gz"
    local url=$(github_proxy_url "https://github.com/Homavi88/Stealthsurf-Asus/releases/latest/download/$asset")
    local url_legacy=$(github_proxy_url "https://github.com/Homavi88/Stealthsurf-Asus/releases/latest/download/$asset_legacy")

    if [ "$specific_version" != "latest" ]; then
        url=$(github_proxy_url "https://github.com/Homavi88/Stealthsurf-Asus/releases/download/v$specific_version/$asset")
        url_legacy=$(github_proxy_url "https://github.com/Homavi88/Stealthsurf-Asus/releases/download/v$specific_version/$asset_legacy")
    fi

    mkdir -p "$ADDON_TMP_DIR" 2>/dev/null
    local temp_file="$ADDON_TMP_DIR/$asset"
    local jffs_addons_path="/jffs/addons"

    log_info "Downloading the version:$specific_version..."
    update_loading_progress "Downloading the version:$specific_version..."
    if wget -q --show-progress -O "$temp_file" "$url"; then
        log_info "Download completed successfully."
    elif wget -q --show-progress -O "$temp_file" "$url_legacy"; then
        log_info "Download completed via legacy asset $asset_legacy."
    else
        log_error "Failed to download the $specific_version version. Exiting."
        return 1
    fi

    # Never touch official StealthSurf VPN at /jffs/addons/stealthsurf
    if [ -x "$OFFICIAL_SS_DAEMON" ]; then
        log_info "Official StealthSurf VPN present at $OFFICIAL_SS_JFFS_DIR — leaving it alone."
    fi

    log_info "Cleaning up existing installation at $ADDON_JFFS_ADN_DIR..."
    if rm -rf "$ADDON_JFFS_ADN_DIR"; then
        log_info "Old installation removed."
    else
        log_error "Failed to remove the old installation. Exiting."
        return 1
    fi

    # Also drop a mistaken 1.2.0 copy under the official path (no routerd).
    if [ ! -x "$OFFICIAL_SS_DAEMON" ] && { [ -f "$OFFICIAL_SS_JFFS_DIR/index.asp" ] || [ -f "$OFFICIAL_SS_JFFS_DIR/app.js" ]; }; then
        log_warn "Removing leftover Homavi88 files from $OFFICIAL_SS_JFFS_DIR (official daemon absent)."
        rm -rf "$OFFICIAL_SS_JFFS_DIR/index.asp" "$OFFICIAL_SS_JFFS_DIR/app.js" \
            "$OFFICIAL_SS_JFFS_DIR/index.panel.html" "$OFFICIAL_SS_JFFS_DIR/panel" \
            "$OFFICIAL_SS_JFFS_DIR/stealthsurf" 2>/dev/null || true
    fi

    log_info "Extracting the package..."
    update_loading_progress "Extracting the package..."
    if tar -xzf "$temp_file" -C "$jffs_addons_path"; then
        log_info "Extraction completed."
    else
        log_error "Failed to extract the package. Exiting."
        return 1
    fi

    # Legacy archives still used stealthsurf/ as the root folder name
    if [ ! -f "$ADDON_JFFS_ADN_DIR/stealthsurf" ] && [ -f "$jffs_addons_path/stealthsurf/stealthsurf" ]; then
        if [ -x "$OFFICIAL_SS_DAEMON" ]; then
            log_error "Legacy package root collides with official StealthSurf VPN. Aborting."
            return 1
        fi
        rm -rf "$ADDON_JFFS_ADN_DIR"
        mv -f "$jffs_addons_path/stealthsurf" "$ADDON_JFFS_ADN_DIR" || {
            log_error "Failed to relocate legacy package to $ADDON_JFFS_ADN_DIR"
            return 1
        }
    fi

    log_info "Setting up the script..."
    update_loading_progress "Setting up the script..."
    if mv "$ADDON_JFFS_ADN_DIR/stealthsurf" "$ADDON_SCRIPT" && chmod 0777 "$ADDON_SCRIPT"; then
        log_ok "Script set up successfully."
    else
        log_error "Failed to set up the script. Exiting."
        return 1
    fi

    log_info "Running the installation..."
    update_loading_progress "Running the installation..."
    if sh "$ADDON_SCRIPT" install; then
        log_ok "Installation completed successfully."
    else
        log_error "Installation finished with errors. The details are above."
        return 1
    fi

    log_ok "Update process completed!"
}
