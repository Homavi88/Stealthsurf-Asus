#!/bin/sh
# shellcheck disable=SC2034  # codacy:Unused variables

# Compare dotted versions: echo 1 if $1 > $2, 0 if equal, -1 if $1 < $2
addon_version_cmp() {
    local a="$1" b="$2"
    a=${a#v}
    b=${b#v}
    # shellcheck disable=SC2086
    set -- $(echo "$a" | tr '.' ' ')
    local a1=${1:-0} a2=${2:-0} a3=${3:-0}
    # shellcheck disable=SC2086
    set -- $(echo "$b" | tr '.' ' ')
    local b1=${1:-0} b2=${2:-0} b3=${3:-0}
    a1=${a1%%[!0-9]*}; a2=${a2%%[!0-9]*}; a3=${a3%%[!0-9]*}
    b1=${b1%%[!0-9]*}; b2=${b2%%[!0-9]*}; b3=${b3%%[!0-9]*}
    [ -n "$a1" ] || a1=0
    [ -n "$a2" ] || a2=0
    [ -n "$a3" ] || a3=0
    [ -n "$b1" ] || b1=0
    [ -n "$b2" ] || b2=0
    [ -n "$b3" ] || b3=0
    if [ "$a1" -gt "$b1" ]; then echo 1; return; fi
    if [ "$a1" -lt "$b1" ]; then echo -1; return; fi
    if [ "$a2" -gt "$b2" ]; then echo 1; return; fi
    if [ "$a2" -lt "$b2" ]; then echo -1; return; fi
    if [ "$a3" -gt "$b3" ]; then echo 1; return; fi
    if [ "$a3" -lt "$b3" ]; then echo -1; return; fi
    echo 0
}

addon_update_status_write() {
    local latest="$1"
    local current="$2"
    local available="$3"
    local message="$4"
    local checked
    checked=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%d %H:%M:%S')
    mkdir -p "$(dirname "$ADDON_UPDATE_STATUS_FILE")" 2>/dev/null || true
    jq -n \
        --arg latest "$latest" \
        --arg current "$current" \
        --argjson available "$available" \
        --arg checked "$checked" \
        --arg repo "${ADDON_REPO:-Homavi88/Stealthsurf-Asus}" \
        --arg message "$message" \
        '{
          repo: $repo,
          current: $current,
          latest: $latest,
          update_available: $available,
          checked_at: $checked,
          message: $message
        }' >"${ADDON_UPDATE_STATUS_FILE}.$$" &&
        mv -f "${ADDON_UPDATE_STATUS_FILE}.$$" "$ADDON_UPDATE_STATUS_FILE"
    # Publish for panel
    if [ -d "$ADDON_WEB_DIR" ]; then
        ln -s -f "$ADDON_UPDATE_STATUS_FILE" "$ADDON_WEB_DIR/addon-update-status.json" 2>/dev/null ||
            cp -f "$ADDON_UPDATE_STATUS_FILE" "$ADDON_WEB_DIR/addon-update-status.json" 2>/dev/null || true
    fi
}

# Keep Merlin custom_settings / NVRAM in lockstep with the running script version.
# Stale stealthsurf_version (e.g. after install when the UI preferred the cache) kept
# showing «update available» even after a successful upgrade + page reload.
sync_stealthsurf_version_setting() {
    # Never call from panel bootstrap CGI — keep that path read-only / stdout-clean.
    local want="${1:-$XRAYUI_VERSION}"
    want=${want#v}
    [ -n "$want" ] || return 0
    local have=""
    have=$(am_settings_get stealthsurf_version 2>/dev/null || true)
    have=${have#v}
    if [ "$have" != "$want" ]; then
        am_settings_set stealthsurf_version "$want" 2>/dev/null || true
    fi
    return 0
}

# Query GitHub releases/latest for Homavi88/Stealthsurf-Asus; optionally auto-install.
addon_update_check_run() {
    load_xrayui_config
    local repo="${ADDON_REPO:-Homavi88/Stealthsurf-Asus}"
    local current="${XRAYUI_VERSION:-0.0.0}"
    local api_url="https://api.github.com/repos/${repo}/releases/latest"
    local out="${ADDON_TMP_DIR}/ssurf_release_latest.json"
    local latest="" cmp available=false msg

    mkdir -p "$ADDON_TMP_DIR" 2>/dev/null || true
    log_info "Checking GitHub for SurfGate updates ($repo)…"

    # 1) releases/latest JSON  2) releases list JSON  3) HTML scrape
    if github_download "$api_url" "$out" 40 "releases/latest"; then
        latest=$(jq -r '.tag_name // empty' "$out" 2>/dev/null | sed 's/^v//')
        if [ "$(jq -r '.prerelease // false' "$out" 2>/dev/null)" = "true" ]; then
            log_debug "Latest GitHub release is a prerelease: v$latest"
            # Prefer first non-prerelease from list when /latest is a prerelease
            local list_out="${ADDON_TMP_DIR}/ssurf_release_list.json"
            if github_download "https://api.github.com/repos/${repo}/releases?per_page=10" "$list_out" 40 "releases/list"; then
                local stable
                stable=$(jq -r '[.[] | select(.draft==false and .prerelease==false) | .tag_name] | .[0] // empty' "$list_out" 2>/dev/null | sed 's/^v//')
                [ -n "$stable" ] && latest="$stable"
                rm -f "$list_out" 2>/dev/null
            fi
        fi
    fi

    if [ -z "$latest" ]; then
        local list_out="${ADDON_TMP_DIR}/ssurf_release_list.json"
        if github_download "https://api.github.com/repos/${repo}/releases?per_page=10" "$list_out" 40 "releases/list"; then
            latest=$(jq -r '[.[] | select(.draft==false and .prerelease==false) | .tag_name] | .[0] // empty' "$list_out" 2>/dev/null | sed 's/^v//')
            [ -z "$latest" ] && latest=$(jq -r '.[0].tag_name // empty' "$list_out" 2>/dev/null | sed 's/^v//')
        fi
        rm -f "$list_out" 2>/dev/null
    fi

    if [ -z "$latest" ]; then
        # Fallback: HTML of /releases/latest → tag in path
        local html_url="https://github.com/${repo}/releases/latest"
        if github_download "$html_url" "$out" 20 "releases/latest.html"; then
            latest=$(grep -oE 'tag/v?[0-9]+\.[0-9]+(\.[0-9]+)?' "$out" 2>/dev/null | head -n1 | sed 's|^tag/||; s|^v||')
        fi
    fi

    rm -f "$out" 2>/dev/null

    if [ -z "$latest" ]; then
        addon_update_status_write "" "$current" false "GitHub check failed"
        log_warn "Addon update check: could not reach GitHub releases"
        return 1
    fi

    cmp=$(addon_version_cmp "$latest" "$current")
    if [ "$cmp" = "1" ]; then
        available=true
        msg="Update available: v$latest (installed v$current)"
        log_ok "$msg"
    else
        available=false
        msg="Up to date (v$current)"
        log_ok "Addon update check: $msg (latest v$latest)"
    fi

    addon_update_status_write "$latest" "$current" "$available" "$msg"

    if [ "$available" = "true" ] && [ "${addon_auto_update:-false}" = "true" ]; then
        log_info "Auto-update enabled — installing SurfGate v$latest…"
        if update "$latest"; then
            addon_update_status_write "$latest" "$latest" false "Auto-updated to v$latest"
            return 0
        fi
        log_error "Auto-update to v$latest failed"
        return 1
    fi
    return 0
}

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

    # Prefer Entware curl/wget + GitHub mirrors via github_download.
    # Firmware BusyBox wget lacks GNU progress flags and often cannot do HTTPS.
    local asset="asuswrt-merlin-surfgate.tar.gz"
    local asset_legacy="asuswrt-merlin-stealthsurf.tar.gz"
    local url="https://github.com/Homavi88/Stealthsurf-Asus/releases/latest/download/$asset"
    local url_legacy="https://github.com/Homavi88/Stealthsurf-Asus/releases/latest/download/$asset_legacy"

    if [ "$specific_version" != "latest" ]; then
        url="https://github.com/Homavi88/Stealthsurf-Asus/releases/download/v$specific_version/$asset"
        url_legacy="https://github.com/Homavi88/Stealthsurf-Asus/releases/download/v$specific_version/$asset_legacy"
    fi

    mkdir -p "$ADDON_TMP_DIR" 2>/dev/null
    local temp_file="$ADDON_TMP_DIR/$asset"
    local jffs_addons_path="/jffs/addons"
    # Package is several MB; reject HTML error pages / empty bodies.
    local min_bytes=102400

    log_info "Downloading the version:$specific_version..."
    update_loading_progress "Downloading the version:$specific_version..."
    rm -f "$temp_file"
    if github_download "$url" "$temp_file" "$min_bytes" "$asset"; then
        log_info "Download completed successfully."
    elif github_download "$url_legacy" "$temp_file" "$min_bytes" "$asset_legacy"; then
        log_info "Download completed via legacy asset $asset_legacy."
    else
        log_error "Failed to download the $specific_version version. Exiting."
        log_error "Tried: $url"
        log_error "And:   $url_legacy"
        log_error "Fetcher: $(github_https_bin 2>/dev/null || echo none) — install Entware curl if missing."
        log_error "Manual: /opt/bin/curl -fsSL -o /tmp/$asset '$url' && tar -xzf /tmp/$asset -C /jffs/addons && mv /jffs/addons/ssurf/stealthsurf /jffs/scripts/ssurf && chmod 777 /jffs/scripts/ssurf && /jffs/scripts/ssurf install"
        return 1
    fi

    # Never touch /jffs/addons/stealthsurf (official StealthSurf).
    log_info "Cleaning up existing installation at $ADDON_JFFS_ADN_DIR..."
    if rm -rf "$ADDON_JFFS_ADN_DIR"; then
        log_info "Old installation removed."
    else
        log_error "Failed to remove the old installation. Exiting."
        return 1
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

    # Parent shell still holds the pre-update XRAYUI_VERSION — read the new script.
    # Clearing addon-update-status prevents a stale «current: 1.4.x» banner after reload.
    local installed_ver=""
    installed_ver=$(sed -n 's/^XRAYUI_VERSION="\([^"]*\)".*/\1/p' "$ADDON_SCRIPT" 2>/dev/null | head -n1)
    if [ -z "$installed_ver" ] || [ "$installed_ver" = "latest" ]; then
        [ "$specific_version" != "latest" ] && installed_ver="$specific_version"
    fi
    [ -n "$installed_ver" ] || installed_ver="$XRAYUI_VERSION"
    sync_stealthsurf_version_setting "$installed_ver" >/dev/null 2>&1 || true
    addon_update_status_write "$installed_ver" "$installed_ver" false "Updated to v$installed_ver" >/dev/null 2>&1 || true

    # Insurance: install already restarts panel, but a mid-upgrade httpd race left
    # some routers with :1131 down after 1.4.46 — force one more clean start.
    if type panel_restart >/dev/null 2>&1; then
        panel_restart >/dev/null 2>&1 || panel_start >/dev/null 2>&1 || true
    fi

    log_ok "Update process completed!"
}
