#!/bin/sh
# Addon settings: autostart, scheduled reboot, geodata auto-update, backup prefs

SS_SETTINGS_FILE="${SS_SETTINGS_FILE:-$ADDON_SHARE_DIR/settings.json}"

ss_settings_defaults() {
  SS_AUTO_START="${SS_AUTO_START:-1}"
  SS_WATCHDOG="${SS_WATCHDOG:-1}"
  SS_AUTO_BACKUP="${SS_AUTO_BACKUP:-1}"
  SS_BACKUP_KEEP="${SS_BACKUP_KEEP:-10}"
  SS_STARTUP_DELAY="${SS_STARTUP_DELAY:-8}"
  SS_REBOOT_SCHEDULE="${SS_REBOOT_SCHEDULE:-off}" # off|daily|weekly|monthly|custom
  SS_REBOOT_CRON="${SS_REBOOT_CRON:-}"            # used when schedule=custom
  SS_GEODATA_AUTO="${SS_GEODATA_AUTO:-0}"
  SS_GEODATA_SCHEDULE="${SS_GEODATA_SCHEDULE:-weekly}" # daily|every3d|weekly|monthly
  SS_GEODATA_BASE="${SS_GEODATA_BASE:-https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download}"
}

ss_settings_apply_geodata_base() {
  ss_settings_defaults
  if [ -n "$SS_GEODATA_BASE" ]; then
    GEODATA_BASE="$SS_GEODATA_BASE"
  fi
}

ss_settings_publish() {
  # Write settings.json for WebUI and symlink into /www/user
  local json
  json=$(ss_settings_json 2>/dev/null) || return 0
  ss_ensure_dirs
  printf '%s\n' "$json" >"$SS_SETTINGS_FILE"
  if [ -n "${ADDON_WEB_DIR:-}" ]; then
    mkdir -p "$ADDON_WEB_DIR" 2>/dev/null || true
    ln -sf "$SS_SETTINGS_FILE" "$ADDON_WEB_DIR/settings.json" 2>/dev/null ||
      cp -f "$SS_SETTINGS_FILE" "$ADDON_WEB_DIR/settings.json" 2>/dev/null || true
  fi
}

ss_settings_json() {
  ss_settings_defaults
  ss_settings_apply_geodata_base
  jq -nc \
    --arg auto_start "$SS_AUTO_START" \
    --arg watchdog "$SS_WATCHDOG" \
    --arg auto_backup "$SS_AUTO_BACKUP" \
    --arg backup_keep "$SS_BACKUP_KEEP" \
    --arg startup_delay "$SS_STARTUP_DELAY" \
    --arg reboot_schedule "$SS_REBOOT_SCHEDULE" \
    --arg reboot_cron "$SS_REBOOT_CRON" \
    --arg geodata_auto "$SS_GEODATA_AUTO" \
    --arg geodata_schedule "$SS_GEODATA_SCHEDULE" \
    --arg geodata_base "$GEODATA_BASE" \
    --arg version "$ADDON_VERSION" \
    '{
      auto_start: ($auto_start == "1"),
      watchdog: ($watchdog == "1"),
      auto_backup: ($auto_backup == "1"),
      backup_keep: ($backup_keep|tonumber? // 10),
      startup_delay: ($startup_delay|tonumber? // 8),
      reboot_schedule: $reboot_schedule,
      reboot_cron: (if $reboot_cron=="" then null else $reboot_cron end),
      geodata_auto: ($geodata_auto == "1"),
      geodata_schedule: $geodata_schedule,
      geodata_base: $geodata_base,
      version: $version
    }'
}

ss_settings_reboot_cron_expr() {
  # Map UI schedule → cron minute hour dom mon dow
  ss_settings_defaults
  case "$SS_REBOOT_SCHEDULE" in
  daily) echo "15 4 * * *" ;;
  weekly) echo "15 4 * * 0" ;;
  monthly) echo "15 4 1 * *" ;;
  custom)
    if [ -n "$SS_REBOOT_CRON" ]; then
      printf '%s\n' "$SS_REBOOT_CRON"
    fi
    ;;
  *) ;; # off
  esac
}

ss_settings_geodata_cron_expr() {
  ss_settings_defaults
  [ "$SS_GEODATA_AUTO" = "1" ] || return 0
  case "$SS_GEODATA_SCHEDULE" in
  daily) echo "30 5 * * *" ;;
  every3d) echo "30 5 */3 * *" ;;
  weekly) echo "30 5 * * 1" ;;
  monthly) echo "30 5 1 * *" ;;
  *) echo "30 5 * * 1" ;;
  esac
}

ss_settings_install_extra_cron() {
  # Optional reboot + geodata jobs (cru preferred)
  local reb geo
  reb=$(ss_settings_reboot_cron_expr 2>/dev/null || true)
  geo=$(ss_settings_geodata_cron_expr 2>/dev/null || true)

  if command -v cru >/dev/null 2>&1; then
    cru d stealthsurf_reboot 2>/dev/null || true
    cru d stealthsurf_geodata 2>/dev/null || true
    # leftover from removed Telegram bot
    cru d stealthsurf_tg 2>/dev/null || true
    if [ -n "$reb" ]; then
      cru a stealthsurf_reboot "$reb /sbin/reboot"
      ss_info "Scheduled router reboot: $reb"
    fi
    if [ -n "$geo" ]; then
      cru a stealthsurf_geodata "$geo /jffs/scripts/$ADDON_TAG geodata"
      ss_info "Scheduled geodata update: $geo"
    fi
    return 0
  fi

  local cronf="/var/spool/cron/crontabs/admin"
  if [ -d "$(dirname "$cronf")" ]; then
    touch "$cronf"
    grep -v '# stealthsurf reboot\|# stealthsurf geodata' "$cronf" >"$cronf.tmp" 2>/dev/null || cp "$cronf" "$cronf.tmp"
    mv "$cronf.tmp" "$cronf"
    if [ -n "$reb" ]; then
      echo "$reb /sbin/reboot # stealthsurf reboot" >>"$cronf"
    fi
    if [ -n "$geo" ]; then
      echo "$geo /jffs/scripts/$ADDON_TAG geodata >/dev/null 2>&1 # stealthsurf geodata" >>"$cronf"
    fi
  fi
}

ss_settings_bool01() {
  # Map JSON bool field → 1/0; empty if missing
  printf '%s' "$1" | jq -r --arg k "$2" '
    if has($k) then
      if .[$k] == true or .[$k] == 1 or .[$k] == "1" then "1"
      elif .[$k] == false or .[$k] == 0 or .[$k] == "0" then "0"
      else empty end
    else empty end' 2>/dev/null || true
}

ss_settings_apply() {
  # Apply JSON payload from WebUI / CLI
  local payload="${1:-{}}"
  local v n
  ss_settings_defaults

  v=$(ss_settings_bool01 "$payload" auto_start)
  [ -n "$v" ] && SS_AUTO_START="$v" || true
  v=$(ss_settings_bool01 "$payload" watchdog)
  [ -n "$v" ] && SS_WATCHDOG="$v" || true
  v=$(ss_settings_bool01 "$payload" auto_backup)
  [ -n "$v" ] && SS_AUTO_BACKUP="$v" || true
  v=$(printf '%s' "$payload" | jq -r '.backup_keep // empty' 2>/dev/null || true)
  [ -n "$v" ] && SS_BACKUP_KEEP="$v" || true
  v=$(printf '%s' "$payload" | jq -r '.startup_delay // empty' 2>/dev/null || true)
  [ -n "$v" ] && SS_STARTUP_DELAY="$v" || true
  v=$(printf '%s' "$payload" | jq -r '.reboot_schedule // empty' 2>/dev/null || true)
  [ -n "$v" ] && SS_REBOOT_SCHEDULE="$v" || true
  # Explicit null/"" clears custom cron; omit key keeps previous value
  v=$(printf '%s' "$payload" | jq -r 'if has("reboot_cron") then (if .reboot_cron == null then "" else (.reboot_cron|tostring) end) else "__omit__" end' 2>/dev/null || true)
  v=$(printf '%s' "$v" | tr -d '\r' | head -n 1)
  case "$v" in
  __omit__) ;;
  *) SS_REBOOT_CRON="$v" ;;
  esac
  v=$(ss_settings_bool01 "$payload" geodata_auto)
  [ -n "$v" ] && SS_GEODATA_AUTO="$v" || true
  v=$(printf '%s' "$payload" | jq -r '.geodata_schedule // empty' 2>/dev/null || true)
  [ -n "$v" ] && SS_GEODATA_SCHEDULE="$v" || true
  v=$(printf '%s' "$payload" | jq -r '.geodata_base // empty' 2>/dev/null || true)
  if [ -n "$v" ]; then
    case "$v" in
    http://* | https://*)
      SS_GEODATA_BASE="${v%/}"
      ;;
    *)
      ss_warn "Ignoring invalid geodata_base URL"
      ;;
    esac
  fi

  # Validate custom reboot cron roughly (5 fields)
  if [ "$SS_REBOOT_SCHEDULE" = "custom" ]; then
    # collapse whitespace; count tokens
    n=$(printf '%s' "$SS_REBOOT_CRON" | tr -s ' \t' ' ' | sed 's/^ *//;s/ *$//' | awk '{print NF}')
    n=$(printf '%s' "$n" | head -n 1)
    case "$n" in
    '' | *[!0-9]*) n=0 ;;
    esac
    if [ -z "$SS_REBOOT_CRON" ] || [ "$n" -lt 5 ]; then
      ss_error "reboot_cron must have 5 fields (min hour dom mon dow)"
      return 1
    fi
  fi

  ss_settings_apply_geodata_base
  ss_save_conf
  ss_settings_publish
  # Refresh base cron + extras
  if type ss_install_cron >/dev/null 2>&1; then
    ss_install_cron 2>/dev/null || true
  else
    ss_settings_install_extra_cron 2>/dev/null || true
  fi
  ss_activity "settings.apply" "auto_start=$SS_AUTO_START reboot=$SS_REBOOT_SCHEDULE geodata_auto=$SS_GEODATA_AUTO"
  ss_ok "Settings saved"
  ss_settings_json
}
