#!/bin/sh
# shellcheck disable=SC2034  # codacy:Unused variables

# Resolve a backup filename under $ADDON_SHARE_DIR/backup — basename only, no traversal.
backup_safe_path() {
    local name="$1"
    local backup_dir="$ADDON_SHARE_DIR/backup"
    name=$(basename -- "$name" 2>/dev/null || basename "$name")
    # Allow only ssurf-/stealthsurf- archives ending in .tar.gz
    case "$name" in
    ssurf-*.tar.gz | stealthsurf-*.tar.gz) ;;
    *)
        log_error "Invalid backup name: $name"
        return 1
        ;;
    esac
    printf '%s/%s\n' "$backup_dir" "$name"
}

# Validate archive members stay under SurfGate / legacy Homavi88 allowlist.
backup_tar_validate() {
    local archive="$1"
    local bad=0
    local member norm tmp
    [ -f "$archive" ] || {
        log_error "Archive not found: $archive"
        return 1
    }
    tmp="${ADDON_TMP_DIR:-/tmp}/ssurf_tar_check.$$"
    mkdir -p "$(dirname "$tmp")" 2>/dev/null || true
    if ! tar -tzf "$archive" >"$tmp" 2>/dev/null; then
        log_error "Cannot list archive: $archive"
        rm -f "$tmp"
        return 1
    fi
    if [ ! -s "$tmp" ]; then
        log_error "Archive is empty: $archive"
        rm -f "$tmp"
        return 1
    fi
    while IFS= read -r member; do
        [ -n "$member" ] || continue
        norm=$(printf '%s' "$member" | sed 's#^\./##; s#^/##')
        case "$norm" in
        *..*)
            log_error "Backup rejected: path traversal in member '$member'"
            bad=1
            break
            ;;
        esac
        case "$norm" in
        opt/etc/xray/ssurf | opt/etc/xray/ssurf/* | \
            opt/etc/ssurf.conf | \
            opt/share/ssurf/data | opt/share/ssurf/data/* | \
            jffs/ssurf_custom | jffs/ssurf_custom/* | \
            opt/etc/xray/stealthsurf | opt/etc/xray/stealthsurf/* | \
            opt/etc/stealthsurf.conf | \
            opt/share/stealthsurf/data | opt/share/stealthsurf/data/* | \
            jffs/stealthsurf_custom | jffs/stealthsurf_custom/*) ;;
        *)
            log_error "Backup rejected: unexpected member '$member'"
            bad=1
            break
            ;;
        esac
    done <"$tmp"
    rm -f "$tmp"
    [ "$bad" = "0" ]
}

# After extract: copy legacy Homavi88 paths into current ssurf locations if needed.
backup_migrate_legacy_extracted() {
    if [ -f /opt/etc/stealthsurf.conf ] && [ ! -f "$XRAYUI_CONFIG_FILE" ]; then
        mkdir -p "$(dirname "$XRAYUI_CONFIG_FILE")" 2>/dev/null || true
        cp -f /opt/etc/stealthsurf.conf "$XRAYUI_CONFIG_FILE" 2>/dev/null || true
        log_info "Migrated legacy stealthsurf.conf → $XRAYUI_CONFIG_FILE"
    fi
    if [ -d /opt/etc/xray/stealthsurf ]; then
        mkdir -p "$XRAY_CONFIG_DIR" 2>/dev/null || true
        cp -a /opt/etc/xray/stealthsurf/. "$XRAY_CONFIG_DIR/" 2>/dev/null || true
        log_info "Migrated legacy xray/stealthsurf → $XRAY_CONFIG_DIR"
    fi
    if [ -d /opt/share/stealthsurf/data ]; then
        mkdir -p "$ADDON_SHARE_DIR/data" 2>/dev/null || true
        cp -a /opt/share/stealthsurf/data/. "$ADDON_SHARE_DIR/data/" 2>/dev/null || true
        log_info "Migrated legacy share data → $ADDON_SHARE_DIR/data"
    fi
    if [ -d /jffs/stealthsurf_custom ]; then
        mkdir -p "$ADDON_USER_SCRIPTS_DIR" 2>/dev/null || true
        cp -a /jffs/stealthsurf_custom/. "$ADDON_USER_SCRIPTS_DIR/" 2>/dev/null || true
        log_info "Migrated legacy custom scripts → $ADDON_USER_SCRIPTS_DIR"
    fi
}

backup_clear() {
    log_info "Starting clear all..."
    update_loading_progress "Clear all backups..."

    local payload backup_file backup_dir target
    backup_dir="$ADDON_SHARE_DIR/backup"
    # CLI: BACKUP_CLEAR_FILE=name or BACKUP_CLEAR_ALL=1
    if [ "${BACKUP_CLEAR_ALL:-0}" = "1" ]; then
        backup_file=""
    elif [ -n "${BACKUP_CLEAR_FILE:-}" ]; then
        backup_file="$BACKUP_CLEAR_FILE"
    else
        payload=$(reconstruct_payload 2>/dev/null || echo '{}')
        backup_file=$(echo "$payload" | jq -r '.backup // empty')
    fi

    if [ -n "$backup_file" ] && [ "$backup_file" != "null" ]; then
        target=$(backup_safe_path "$backup_file") || return 1
        if [ ! -e "$target" ]; then
            log_error "Backup not found: $target"
            return 1
        fi
        rm -f -- "$target"
        if [ $? -ne 0 ]; then
            log_error "Failed to remove backup $target."
            return 1
        fi
        log_ok "Backup $target removed successfully."
    else
        # Delete archives only — never rm -rf the parent share dir
        mkdir -p "$backup_dir"
        find "$backup_dir" -maxdepth 1 -type f \( -name 'ssurf-*.tar.gz' -o -name 'stealthsurf-*.tar.gz' \) -print |
            while IFS= read -r f; do
                rm -f -- "$f"
            done
        log_ok "All SurfGate backups cleared in $backup_dir."
    fi

    backup_remount_to_web
}

backup_configuration() {
    log_info "Starting backup configuration..."
    update_loading_progress "Backup configuration..."

    local backup_dir="$ADDON_SHARE_DIR/backup"
    mkdir -p "$backup_dir"

    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)

    local payload custom_name backup_file
    payload=$(reconstruct_payload 2>/dev/null || echo '{}')
    custom_name=$(echo "$payload" | jq -r '.name // empty')
    # CLI may pass name via BACKUP_NAME
    [ -z "$custom_name" ] && custom_name="${BACKUP_NAME:-}"
    custom_name=$(echo "$custom_name" | sed 's/[^a-zA-Z0-9_-]/-/g; s/--*/-/g; s/^-//; s/-$//' | cut -c1-50)

    if [ -n "$custom_name" ]; then
        backup_file="$backup_dir/ssurf-${timestamp}-${custom_name}.tar.gz"
    else
        backup_file="$backup_dir/ssurf-${timestamp}.tar.gz"
    fi

    local items_list="" item rel
    # Root for relative archive members (tests may set BACKUP_ROOT).
    local backup_root="${BACKUP_ROOT:-/}"
    # Prefer current ssurf custom scripts; also pack legacy dir if it still exists
    for item in \
        "$XRAY_CONFIG_DIR"/*.json \
        "$XRAY_CONFIG_DIR"/cert \
        "$ADDON_USER_SCRIPTS_DIR" \
        "${backup_root%/}/jffs/stealthsurf_custom" \
        "$ADDON_SHARE_DIR/data" \
        "$XRAYUI_CONFIG_FILE"; do
        # Normalise accidental double-slash when backup_root=/
        item=$(printf '%s' "$item" | sed 's#//*#/#g')
        if [ -e "$item" ]; then
            rel=${item#"$backup_root"}
            rel=${rel#/}
            [ -n "$rel" ] || continue
            items_list="$items_list $rel"
        else
            case "$item" in
            */cert | */*_custom | */data)
                log_debug "Optional backup item missing: $item"
                ;;
            *)
                log_warn "Backup item not found: $item"
                ;;
            esac
        fi
    done

    if [ -z "$items_list" ]; then
        log_error "No configuration items found to backup."
        return 1
    fi

    update_loading_progress "Creating backup archive $backup_file..."
    log_info "Creating backup archive $backup_file..."
    # shellcheck disable=SC2086
    if ! tar -C "$backup_root" -czf "$backup_file" $items_list; then
        log_error "Failed to create backup."
        rm -f -- "$backup_file"
        return 1
    fi

    if ! backup_tar_validate "$backup_file"; then
        log_error "Created archive failed self-validation — removing."
        rm -f -- "$backup_file"
        return 1
    fi

    backup_remount_to_web

    log_ok "Backup created successfully: $backup_file"
    # Print path for CLI users
    printf '%s\n' "$backup_file"
}

backup_remount_to_web() {
    local share_backup="$ADDON_SHARE_DIR/backup"
    local web_backup="$ADDON_WEB_DIR/backup"

    rm -rf "$web_backup"

    if ! mkdir -p "$web_backup"; then
        log_error "Error: Failed to create directory '$web_backup'."
        return 1
    fi

    for file in "$share_backup"/*; do
        [ -e "$file" ] || continue
        log_info "Processing file: $file"
        if [ -f "$file" ]; then
            local symlink="$web_backup/$(basename "$file").cab"
            if ! ln -s -f "$file" "$symlink"; then
                log_error "Error: Failed to create symlink '$symlink' -> '$file'."
                return 1
            fi
            log_ok "Created symlink '$symlink' -> '$file'."
        fi
    done

    log_ok "All symlinks created successfully in '$web_backup'."
    return 0
}

# Restore from an absolute path already validated / under backup dir.
backup_restore_from_file() {
    local backup_file="$1"

    log_info "Starting restore configuration..."
    update_loading_progress "Restore configuration..."

    load_xrayui_config

    if [ -z "$backup_file" ]; then
        log_error "No backup file specified. Please provide a .tar.gz file to restore."
        return 1
    fi

    if [ ! -f "$backup_file" ]; then
        log_error "Backup file not found: $backup_file"
        return 1
    fi

    if ! backup_tar_validate "$backup_file"; then
        log_error "Restore aborted: archive failed validation."
        return 1
    fi

    log_info "Starting restore from backup: $backup_file"
    update_loading_progress "Restoring configuration from $backup_file..."

    local restore_root="${BACKUP_ROOT:-/}"
    if ! tar -xzf "$backup_file" -C "$restore_root"; then
        log_error "Failed to extract backup archive $backup_file."
        return 1
    fi

    # Legacy migrate only when restoring onto the real root
    if [ "$restore_root" = "/" ]; then
        backup_migrate_legacy_extracted
    fi

    unset profile
    load_xrayui_config

    if [ ! -f "$XRAY_CONFIG_FILE" ]; then
        log_warn "Restored profile $XRAY_CONFIG_FILE does not exist. Generating default configuration."
        generate_xray_config
    fi

    ln -s -f "$XRAY_CONFIG_FILE" "$ADDON_WEB_DIR/xray-config.json" || log_error "Failed to create symlink for xray-config.json."

    backup_remount_to_web

    log_ok "Restore completed successfully from $backup_file."

    cron_jobs_add

    update_loading_progress "Applying restored profile $XRAY_CONFIG_FILE..."
    restart
}

backup_restore_configuration() {
    local share_backup="$ADDON_SHARE_DIR/backup"
    local payload name path
    payload=$(reconstruct_payload 2>/dev/null || echo '{}')
    name=$(echo "$payload" | jq -r '.file // empty')
    # CLI override
    [ -z "$name" ] && name="${BACKUP_RESTORE_FILE:-}"
    path=$(backup_safe_path "$name") || return 1
    backup_restore_from_file "$path"
}

backup_list() {
    local backup_dir="$ADDON_SHARE_DIR/backup"
    mkdir -p "$backup_dir"
    ls -1t "$backup_dir"/ssurf-*.tar.gz "$backup_dir"/stealthsurf-*.tar.gz 2>/dev/null || true
}

backup_xray_config() {

    log_info "Starting backup xray configuration $XRAY_CONFIG_FILE..."

    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local base_cfg
    base_cfg=$(basename "$XRAY_CONFIG_FILE")
    local backup_dir="$XRAY_CONFIG_DIR"
    local backup_file="${backup_dir}/${base_cfg}.${timestamp}.bak"

    log_info "Backing up $XRAY_CONFIG_FILE to $backup_file"
    cp -f "$XRAY_CONFIG_FILE" "$backup_file"

    local keep=3
    set -- "${backup_dir}/${base_cfg}".*.bak
    [ -e "$1" ] || return 0

    ls -1t "${backup_dir}/${base_cfg}".*.bak 2>/dev/null |
        tail -n +"$((keep + 1))" |
        while IFS= read -r old; do
            rm -f -- "$old"
            log_debug "Removed old backup $old"
        done

}
