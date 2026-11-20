#!/bin/sh
# shellcheck disable=SC2034  # codacy:Unused variables

# ANSI color codes (only used if stdout is a terminal)
CDBG='\033[0;90m'  # gray
CERR='\033[0;31m'  # red
CWARN='\033[0;33m' # yellow
CINFO='\033[0;36m' # cyan
CSUC='\033[0;32m'  # green
CLOG='\033[0;37m'  # white
CRESET='\033[0m'
LOG_FACILITY='user'

if [ -t 1 ]; then
    USE_COLOR=1
else
    USE_COLOR=0
fi

printlog() {
    level=$1
    shift
    msg=$*

    # Map LEVEL → syslog priority & console color
    case "$level" in
    ALERT | CRIT)
        priority='crit'
        color=$CERR
        ;;
    ERROR)
        priority='err'
        color=$CERR
        ;;
    WARN | WARNING)
        priority='warning'
        color=$CWARN
        ;;
    NOTICE)
        priority='notice'
        color=$CINFO
        ;;

    LOG)
        priority='info'
        color=$CLOG
        ;;
    INFO)
        priority='info'
        color=$CINFO
        ;;
    DEBUG)
        priority='debug'
        color=$CDBG
        ;;
    SUCCESS | OK)
        priority='info'
        color=$CSUC
        ;;
    *)
        priority='info'
        color=$CINFO
        ;;
    esac

    logger -t "SSURF" -p "${LOG_FACILITY}.${priority}" -- "$msg"

    # Durable app activity log (panel Settings → logs → App)
    if [ -n "${ADDON_LOGS_DIR:-}" ]; then
        if [ "$level" != "DEBUG" ] || [ "${ADDON_DEBUG:-false}" = "true" ]; then
            mkdir -p "$ADDON_LOGS_DIR" 2>/dev/null || true
            _ss_app_log="${ADDON_LOGS_DIR}/ssurf_app.log"
            _ss_ts=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date)
            printf '%s [%s] %s\n' "$_ss_ts" "$level" "$msg" >>"$_ss_app_log" 2>/dev/null || true
            # Soft-rotate when over ~2 MiB
            if [ -f "$_ss_app_log" ]; then
                _ss_sz=$(wc -c <"$_ss_app_log" 2>/dev/null | tr -d ' ')
                if [ -n "$_ss_sz" ] && [ "$_ss_sz" -gt 2097152 ] 2>/dev/null; then
                    tail -n 1500 "$_ss_app_log" >"${_ss_app_log}.trim" 2>/dev/null &&
                        mv -f "${_ss_app_log}.trim" "$_ss_app_log" 2>/dev/null ||
                        rm -f "${_ss_app_log}.trim" 2>/dev/null
                fi
            fi
        fi
    fi

    if [ "$ADDON_DEBUG" = "false" ] && [ "$level" = "DEBUG" ]; then
        return
    fi

    if [ "$USE_COLOR" -eq 1 ]; then
        printf '%b%s%b\n' "$color" "$msg" "$CRESET"
    else
        printf '%s\n' "$msg"
    fi
}

log_alert() { printlog ALERT "$@"; }
log_crit() { printlog CRIT "$@"; }
log_error() { printlog ERROR "$@"; }
log_warn() { printlog WARN "$@"; }
log_notice() { printlog NOTICE "$@"; }
log_info() { printlog INFO "$@"; }
log_log() { printlog LOG "$@"; }
log_ok() { printlog OK "$@"; }
log_debug() { printlog DEBUG "$@"; }

log_info_box() {
    log_box "$1" "$CINFO"
}

log_warn_box() {
    log_box "$1" "$CWARN"
}

log_error_box() {
    log_box "$1" "$CERR"
}

log_box() {
    msg="$1"
    padding=2
    len=$(printf '%s' "$msg" | wc -c)
    width=$((len + padding * 2))
    color="${2:-$CSUC}"

    border=''
    i=0
    while [ "$i" -lt "$width" ]; do
        border="${border}═"
        i=$((i + 1))
    done

    printf '%b╔%s╗\n' "$color" "$border"
    printf '%b║%*s║\n' "$color" "$width" ''
    printf '%b║%*s%s%*s║\n' "$color" "$padding" '' "$msg" "$padding" ''
    printf '%b║%*s║\n' "$color" "$width" ''
    printf '%b╚%s╝%b\n' "$color" "$border" "$CRESET"
}

# ── SurfGate colorful install progress (TTY) ──────────────────────────────
INSTALL_UI_TOTAL=1
INSTALL_UI_STEP=0
INSTALL_UI_WIDTH=28
CBAR='\033[0;36m'
CDIM='\033[0;90m'
CBLD='\033[1m'

install_ui_humansize() {
    local n="$1"
    if [ -z "$n" ]; then
        echo "?"
        return
    fi
    if [ "$n" -ge 1048576 ] 2>/dev/null; then
        awk -v n="$n" 'BEGIN { printf "%.1f MB", n/1048576 }'
    elif [ "$n" -ge 1024 ] 2>/dev/null; then
        awk -v n="$n" 'BEGIN { printf "%.0f KB", n/1024 }'
    else
        printf '%s B' "$n"
    fi
}

install_ui_bar_draw() {
    local pct="$1"
    local filled empty i bar
    [ "$pct" -gt 100 ] 2>/dev/null && pct=100
    [ "$pct" -lt 0 ] 2>/dev/null && pct=0
    filled=$((pct * INSTALL_UI_WIDTH / 100))
    empty=$((INSTALL_UI_WIDTH - filled))
    bar=''
    i=0
    while [ "$i" -lt "$filled" ]; do
        bar="${bar}█"
        i=$((i + 1))
    done
    i=0
    while [ "$i" -lt "$empty" ]; do
        bar="${bar}░"
        i=$((i + 1))
    done
    printf '%s' "$bar"
}

install_ui_begin() {
    local title="${1:-SurfGate install}"
    local total="${2:-10}"
    INSTALL_UI_TOTAL=$total
    INSTALL_UI_STEP=0

    if [ "${USE_COLOR:-0}" -eq 1 ]; then
        printf '\n'
        printf '%b┌─ %b%s%b ─────────────────────────────┐%b\n' "$CBAR" "$CBLD" "$title" "$CBAR" "$CRESET"
        printf '%b│%b colorful progress · modules · geodata %b│%b\n' "$CBAR" "$CDIM" "$CBAR" "$CRESET"
        printf '%b└──────────────────────────────────────────────┘%b\n' "$CBAR" "$CRESET"
    else
        log_info "=== $title ($total steps) ==="
    fi
}

install_ui_step() {
    local label="$1"
    local pct
    INSTALL_UI_STEP=$((INSTALL_UI_STEP + 1))
    [ "$INSTALL_UI_TOTAL" -lt 1 ] && INSTALL_UI_TOTAL=1
    pct=$((INSTALL_UI_STEP * 100 / INSTALL_UI_TOTAL))
    [ "$pct" -gt 100 ] && pct=100

    update_loading_progress "$label" "$pct" 2>/dev/null || true

    if [ "${USE_COLOR:-0}" -eq 1 ]; then
        printf '%b[%b%s%b]%b %3d%%  %b%2d/%d%b  %s\n' \
            "$CDIM" "$CBAR" "$(install_ui_bar_draw "$pct")" "$CDIM" "$CRESET" \
            "$pct" "$CDIM" "$INSTALL_UI_STEP" "$INSTALL_UI_TOTAL" "$CRESET" "$label"
    else
        log_info "[$pct%] ($INSTALL_UI_STEP/$INSTALL_UI_TOTAL) $label"
    fi
}

install_ui_status() {
    local kind="$1"
    local msg="$2"
    local mark color

    case "$kind" in
    ok | success)
        mark='✓'
        color=$CSUC
        ;;
    fail | error)
        mark='✗'
        color=$CERR
        ;;
    skip | warn)
        mark='!'
        color=$CWARN
        ;;
    run | info)
        mark='›'
        color=$CINFO
        ;;
    *)
        mark='·'
        color=$CLOG
        ;;
    esac

    if [ "${USE_COLOR:-0}" -eq 1 ]; then
        printf '  %b%s%b %s\n' "$color" "$mark" "$CRESET" "$msg"
    else
        log_info "[$kind] $msg"
    fi
}

install_ui_fetch() {
    local label="$1"
    local url="$2"
    local attempt="$3"
    local short
    short=$(printf '%s' "$url" | sed 's#https://##; s#http://##')
    short=$(printf '%.64s' "$short")
    if [ "${USE_COLOR:-0}" -eq 1 ]; then
        printf '  %b↓%b %s  %btry %s%b  %b%s%b\n' \
            "$CBAR" "$CRESET" "$label" "$CDIM" "$attempt" "$CRESET" "$CDIM" "$short" "$CRESET"
    else
        log_info "↓ $label (try $attempt)"
    fi
}

install_ui_end() {
    local ok_msg="${1:-Installation finished}"
    if [ "${USE_COLOR:-0}" -eq 1 ]; then
        printf '%b[%b%s%b]%b 100%%  done\n' \
            "$CDIM" "$CSUC" "$(install_ui_bar_draw 100)" "$CDIM" "$CRESET"
        install_ui_status ok "$ok_msg"
        printf '\n'
    else
        log_ok "$ok_msg"
    fi
}

# PATH puts /opt/sbin first, so a bare `modprobe` resolves to Entware's kmod,
# which can fail to load firmware modules. Prefer the firmware's own modprobe.
kmod_load() {
    if [ -x /sbin/modprobe ]; then
        /sbin/modprobe "$@"
    else
        modprobe "$@"
    fi
}

# Read /proc/modules directly instead of `lsmod`, which has the same PATH issue.
kmod_is_loaded() {
    grep -q "^$1 " /proc/modules 2>/dev/null
}

get_proc() {
    local proc_name="$1"
    echo $(/bin/pidof "$proc_name" 2>/dev/null | awk '{print $NF}')
}

is_xray_daemon_cmdline() {
    local args
    case "${1%% *}" in
    xray | */xray) ;;
    *) return 1 ;;
    esac
    case "$1" in
    *" "*) args="${1#* }" ;;
    *) args="" ;;
    esac
    case " $args " in
    *" -test "* | *" --test "* | *" -test="* | *" --test="* | *" -dump "* | *" --dump "* | *" -dump="* | *" --dump="* | *" -version "* | *" --version "* | *" -h "* | *" -help "* | *" --help "*) return 1 ;;
    esac
    case "${args%% *}" in
    "" | run | -*) return 0 ;;
    esac
    return 1
}

is_xray_daemon_pid() {
    local cmdline
    [ -n "$1" ] || return 1
    [ -r "/proc/$1/cmdline" ] || return 1
    cmdline=$(tr '\0' ' ' <"/proc/$1/cmdline" 2>/dev/null)
    is_xray_daemon_cmdline "$cmdline" || return 1
    # Only claim processes started with OUR config (never stock XrayUI's config.json)
    case " $cmdline " in
    *" $XRAY_CONFIG_FILE "* | *" -c $XRAY_CONFIG_FILE "* | *" -config $XRAY_CONFIG_FILE "*) return 0 ;;
    *" $XRAY_CONFIG_DIR/"*) return 0 ;;
    esac
    return 1
}

get_xray_daemon_pids() {
    local pid cmdline found=0
    for pid in $(/bin/pidof xray 2>/dev/null); do
        if is_xray_daemon_pid "$pid"; then
            echo "$pid"
            found=1
        fi
    done
    # Fallback: /proc scan when pidof misses our process (BusyBox gaps / non-"xray" argv0).
    if [ "$found" -eq 0 ]; then
        for pid in /proc/[0-9]*; do
            pid=${pid#/proc/}
            [ -r "/proc/$pid/cmdline" ] || continue
            cmdline=$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null)
            case "$cmdline" in
            *xray*) ;;
            *) continue ;;
            esac
            is_xray_daemon_pid "$pid" || continue
            echo "$pid"
        done
    fi
}

get_xray_daemon_pid() {
    local pid
    if [ -f "$XRAY_PIDFILE" ]; then
        pid=$(cat "$XRAY_PIDFILE" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && is_xray_daemon_pid "$pid"; then
            echo "$pid"
            return 0
        fi
        # Pidfile points at a live process still using our config dir.
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && [ -r "/proc/$pid/cmdline" ]; then
            case " $(tr '\0' ' ' <"/proc/$pid/cmdline") " in
            *" $XRAY_CONFIG_DIR/"*)
                echo "$pid"
                return 0
                ;;
            esac
        fi
    fi

    pid=$(get_xray_daemon_pids | head -n 1)
    [ -n "$pid" ] || return 1
    echo "$pid"
}

kill_xray_daemon() {
    local sig="${1:--TERM}"
    local pid
    for pid in $(get_xray_daemon_pids); do
        log_debug "Sending $sig to Xray daemon (PID: $pid)."
        kill "$sig" "$pid" 2>/dev/null
    done
}

get_proc_uptime() {
    local pid
    if [ "$1" = "xray" ]; then
        pid=$(get_xray_daemon_pid)
    else
        pid=$(pidof "$1")
    fi

    if [ -z "$pid" ] || [ ! -f "/proc/$pid/stat" ]; then
        echo 0
        return
    fi

    local uptime_s=$(cut -d. -f1 /proc/uptime)
    local localstart_time_jiffies=$(awk '{print $22}' /proc/$pid/stat)

    local jiffies_per_sec=100

    local process_start_s=$((localstart_time_jiffies / jiffies_per_sec))

    local proc_uptime=$((uptime_s - process_start_s))
    echo $proc_uptime
}

sanitize_probe_interval() {
    # Default 60s: concurrent probes of many outbounds every 30s were eating Merlin RAM.
    # Absolute floor stays 5s for tiny configs; api_write_config raises to 30s when >5 tags.
    local v="${1:-60}"
    case "$v" in
    '' | *[!0-9]*) v=60 ;;
    esac
    while [ "${#v}" -gt 1 ] && [ "${v#0}" != "$v" ]; do v="${v#0}"; done
    if [ "$v" -lt 5 ]; then
        v=5
    elif [ "$v" -gt 3600 ]; then
        v=3600
    fi
    echo "$v"
}

get_webui_page() {
    ADDON_USER_PAGE="none"
    local max_user_page=0
    local used_pages=""

    for page in /www/user/user*.asp; do
        if [ -f "$page" ]; then
            if grep -q "page:$ADDON_TAG" "$page"; then
                ADDON_USER_PAGE=$(basename "$page")
                log_ok "Found existing $ADDON_TAG_UPPER page: $ADDON_USER_PAGE"
                return
            fi

            user_number=$(echo "$page" | sed -E 's/.*user([0-9]+)\.asp$/\1/')
            used_pages="$used_pages $user_number"

            if [ "$user_number" -gt "$max_user_page" ]; then
                max_user_page="$user_number"
            fi
        fi
    done

    if [ "$ADDON_USER_PAGE" != "none" ]; then
        log_ok "Found existing $ADDON_TAG_UPPER page: $ADDON_USER_PAGE"
        return
    fi

    if [ "$1" = "true" ]; then
        i=1
        while true; do
            if ! echo "$used_pages" | grep -qw "$i"; then
                ADDON_USER_PAGE="user$i.asp"
                log_ok "Assigning new $ADDON_TAG_UPPER page: $ADDON_USER_PAGE"
                return
            fi
            i=$((i + 1))
        done
    fi
}

am_settings_del() {
    local key="$1"
    custom_settings_drop "/$key/d"
}

custom_settings_drop() {
    local settings=/jffs/addons/custom_settings.txt
    local staged="/tmp/custom_settings.$$"
    local tmp="$settings.$$"
    if sed "$1" "$settings" >"$staged" && cat "$staged" >"$tmp" && mv -f "$tmp" "$settings"; then
        rm -f "$staged"
        return 0
    fi
    rm -f "$staged" "$tmp"
    return 1
}

remove_json_comments() {
    local tempconfig="/tmp/xray-config-clean.json"
    sed 's/\/\/.*//' "$XRAY_CONFIG_FILE" >$tempconfig
    echo $tempconfig
}

XRAYUI_STAGING_DIR="/tmp/stealthsurf-staging"

reconstruct_payload() {

    local session
    session=$(am_settings_get stealthsurf_staged_session)

    if [ -n "$session" ]; then
        reconstruct_staged_payload "$session"
        return
    fi

    local idx=0
    local chunk
    local payload=""
    while :; do
        chunk=$(am_settings_get stealthsurf_payload$idx)
        if [ -z "$chunk" ]; then
            break
        fi
        payload="$payload$chunk"
        idx=$((idx + 1))
    done

    cleanup_payload

    decode_payload "$payload"

}

b64_decode() {
    if which base64 >/dev/null 2>&1; then
        base64 -d 2>/dev/null
    else
        tr -d '\r\n' | openssl base64 -d -A 2>/dev/null
    fi
}

decode_payload() {
    local raw="$1"
    case "$raw" in
        gz:*)
            local decoded
            decoded=$(
                b64_decode <<EOF | gunzip 2>/dev/null
${raw#gz:}
EOF
            )
            if [ -z "${decoded:+1}" ]; then
                log_error "decode_payload: failed to decompress gz: payload (base64/gunzip pipeline failed or produced empty output)" >&2
                return 1
            fi
            cat <<EOF
$decoded
EOF
            ;;
        *)
            cat <<EOF
$raw
EOF
            ;;
    esac
}

reconstruct_staged_payload() {
    # NOTE: this function is called via $(...) substitution; ALL log output MUST go to stderr,
    # otherwise it gets captured as part of the returned payload and corrupts the assembled JSON.
    local session="$1"
    local safe_session
    safe_session=$(printf '%s' "$session" | tr -cd 'A-Za-z0-9_-' | cut -c1-64)

    if [ -z "$safe_session" ] || [ "$safe_session" != "$session" ]; then
        log_error "Invalid staged session id: '$session'" >&2
        cleanup_staged_marker >&2
        return 1
    fi

    local dir="$XRAYUI_STAGING_DIR/$safe_session"
    if [ ! -d "$dir" ]; then
        log_error "Staged session directory missing: $dir" >&2
        cleanup_staged_marker >&2
        return 1
    fi

    local total
    total=$(cat "$dir/total" 2>/dev/null)
    if [ -z "$total" ] || ! [ "$total" -gt 0 ] 2>/dev/null; then
        log_error "Staged session $safe_session has invalid total: '$total'" >&2
        cleanup_staging "$safe_session" >&2
        cleanup_staged_marker >&2
        return 1
    fi

    local tmp_assembly="/tmp/stealthsurf-staged-assembly.$$"
    : >"$tmp_assembly"

    local idx=0
    while [ "$idx" -lt "$total" ]; do
        local chunk_file="$dir/chunk-$idx"
        if [ ! -f "$chunk_file" ]; then
            log_error "Staged chunk $idx of $total missing for session $safe_session" >&2
            rm -f "$tmp_assembly"
            cleanup_staging "$safe_session" >&2
            cleanup_staged_marker >&2
            return 1
        fi
        cat "$chunk_file" >>"$tmp_assembly"
        idx=$((idx + 1))
    done

    local assembled_size
    assembled_size=$(wc -c <"$tmp_assembly" 2>/dev/null)
    log_info "reconstruct_staged_payload: session $safe_session, $total chunks → $assembled_size bytes assembled" >&2

    cleanup_staging "$safe_session" >&2
    cleanup_staged_marker >&2
    cleanup_payload >&2

    local assembled
    assembled=$(cat "$tmp_assembly")
    rm -f "$tmp_assembly"
    decode_payload "$assembled"
}

cleanup_payload() {
    grep -q '^stealthsurf_payload' /jffs/addons/custom_settings.txt 2>/dev/null || return 0
    custom_settings_drop '/^stealthsurf_payload/d'
}

cleanup_staged_marker() {
    grep -qE '^stealthsurf_stag(ed_session|e_)' /jffs/addons/custom_settings.txt 2>/dev/null || return 0
    custom_settings_drop '/^stealthsurf_staged_session/d;/^stealthsurf_stage_/d'
}

cleanup_staging() {
    local session="$1"
    if [ -n "$session" ]; then
        rm -rf "$XRAYUI_STAGING_DIR/$session"
    fi
    sweep_stale_staging
}

sweep_stale_staging() {
    [ -d "$XRAYUI_STAGING_DIR" ] || return 0
    local now d mtime
    now=$(date +%s)
    for d in "$XRAYUI_STAGING_DIR"/*; do
        [ -d "$d" ] || continue
        mtime=$(date -r "$d" +%s 2>/dev/null) || continue
        [ $((now - mtime)) -gt 300 ] && rm -rf "$d"
    done
    return 0
}

stage_chunk() {
    local session
    local index
    local total
    local data

    session=$(am_settings_get stealthsurf_stage_session)
    index=$(am_settings_get stealthsurf_stage_index)
    total=$(am_settings_get stealthsurf_stage_total)
    data=$(am_settings_get stealthsurf_stage_data)

    local safe_session
    safe_session=$(printf '%s' "$session" | tr -cd 'A-Za-z0-9_-' | cut -c1-64)

    if [ -z "$safe_session" ] || [ "$safe_session" != "$session" ]; then
        log_error "stage_chunk: invalid session id: '$session'"
        cleanup_staged_marker
        return 1
    fi

    if ! [ "$index" -ge 0 ] 2>/dev/null || ! [ "$total" -gt 0 ] 2>/dev/null; then
        log_error "stage_chunk: invalid index/total ($index/$total) for session $safe_session"
        cleanup_staged_marker
        return 1
    fi

    if [ "$index" -ge "$total" ]; then
        log_error "stage_chunk: index $index out of range (total $total)"
        cleanup_staged_marker
        return 1
    fi

    mkdir -p "$XRAYUI_STAGING_DIR/$safe_session"
    chmod 700 "$XRAYUI_STAGING_DIR" "$XRAYUI_STAGING_DIR/$safe_session" 2>/dev/null

    echo "$total" >"$XRAYUI_STAGING_DIR/$safe_session/total"
    printf '%s' "$data" >"$XRAYUI_STAGING_DIR/$safe_session/chunk-$index"

    local stored_size
    stored_size=$(wc -c <"$XRAYUI_STAGING_DIR/$safe_session/chunk-$index" 2>/dev/null)
    log_info "stage_chunk: stored chunk $index/$total ($stored_size bytes) for session $safe_session"

    cleanup_staged_marker

    sweep_stale_staging

    return 0
}

load_ui_response() {

    if [ ! -f "$UI_RESPONSE_FILE" ]; then
        log_ok "Creating $ADDON_TITLE response file: $UI_RESPONSE_FILE"
        echo '{}' >"$UI_RESPONSE_FILE"
        chmod 600 "$UI_RESPONSE_FILE"
    fi

    UI_RESPONSE=$(cat "$UI_RESPONSE_FILE")
    if [ -z "$UI_RESPONSE" ] || ! echo "$UI_RESPONSE" | jq empty 2>/dev/null; then
        log_warn "Response file is empty or contains invalid JSON, resetting to {}"
        UI_RESPONSE="{}"
        echo '{}' >"$UI_RESPONSE_FILE"
    fi
}

save_ui_response() {

    log_debug "Saving UI response to $UI_RESPONSE_FILE"

    if [ -z "$UI_RESPONSE" ]; then
        log_error "UI_RESPONSE is empty, refusing to overwrite $UI_RESPONSE_FILE"
        return 1
    fi

    if ! echo "$UI_RESPONSE" >"$UI_RESPONSE_FILE"; then
        log_error "Failed to save UI response to $UI_RESPONSE_FILE"
        clear_lock
        return 1
    fi

}

test_xray_config() {
    log_info "Testing Xray configuration..."
    update_loading_progress "Testing Xray configuration..."

    load_xrayui_config
    local skip_test="${skip_test:-false}"

    if [ "$skip_test" = "true" ]; then
        log_info "Skipping Xray configuration test as per user settings."
        return
    fi

    local output extra_cfg=""

    if api_config_required; then
        [ -f "$(api_get_current_config)" ] || api_apply_configuration
        [ -f "$(api_get_current_config)" ] && extra_cfg="-c $(api_get_current_config)"
    fi

    local test_ok=0
    if ! output=$(xray -c $XRAY_CONFIG_FILE $extra_cfg -test 2>&1); then
        test_ok=1
        message=$(echo "$output" | sed -n '/> infra\/conf:/ {s/.*> infra\/conf: //p}')
        if [ -z "$message" ]; then
            message="$output"
        fi
        message=$(echo "$message" | sed 's/"/\\"/g')
    else
        message="Config file appears to be fine, but the XRAY service has not started. Try to restart/reconnect it."
    fi

    log_info "Xray config test result: $output"

    load_ui_response

    local json_content
    json_content=$(jq --arg msg "$message" '.xray.test = $msg' "$UI_RESPONSE_FILE" 2>/dev/null)
    if [ -z "$json_content" ]; then
        log_warn "Failed to update test result in response file."
        return 1
    fi
    echo "$json_content" >"/tmp/xray-response.$$.tmp" && mv -f "/tmp/xray-response.$$.tmp" "$UI_RESPONSE_FILE"
    return "$test_ok"
}

update_loading_progress() {
    local message=$1
    local progress=$2

    if [ ! -d "$ADDON_WEB_DIR" ]; then
        return
    fi

    load_ui_response

    local json_content
    if [ -f "$UI_RESPONSE_FILE" ]; then
        json_content=$(cat "$UI_RESPONSE_FILE")
    else
        json_content="{}"
    fi

    if [ -n "$progress" ]; then
        json_content=$(echo "$json_content" | jq --argjson progress "$progress" --arg message "$message" '
            .loading.message = $message |
            .loading.progress = $progress
        ')
    else
        json_content=$(echo "$json_content" | jq --arg message "$message" '
            .loading.message = $message
        ')
    fi

    if [ -z "$json_content" ]; then
        log_warn "Failed to update loading progress in response file."
        return 1
    fi

    echo "$json_content" >"/tmp/xray-response.$$.tmp" && mv -f "/tmp/xray-response.$$.tmp" "$UI_RESPONSE_FILE"

    if [ "$progress" = "100" ]; then
        "$ADDON_SCRIPT" service_event cleanloadingprogress >/dev/null 2>&1 &
    fi

}

remove_loading_progress() {

    log_info "Removing loading progress..."
    if [ ! -d "$ADDON_WEB_DIR" ]; then
        return
    fi

    sleep 1
    local message
    message=$(jq -r '.loading.message // empty' "$UI_RESPONSE_FILE" 2>/dev/null)
    case "$message" in
    Error*) sleep 5 ;;
    *) message="" ;;
    esac
    load_ui_response

    local json_content=$(cat "$UI_RESPONSE_FILE")

    json_content=$(echo "$json_content" | jq --arg m "$message" 'if $m == "" or .loading.message == $m then del(.loading) else . end' 2>/dev/null)

    if [ -z "$json_content" ]; then
        log_warn "Failed to remove loading progress from response file."
        return 1
    fi

    echo "$json_content" >"/tmp/xray-response.$$.tmp" && mv -f "/tmp/xray-response.$$.tmp" "$UI_RESPONSE_FILE"
}

fixme() {
    log_info "Attempting to fix XRAY UI issues..."

    local jffs_usage=$(df /jffs 2>/dev/null | awk 'NR==2 {print $5}' | tr -d '%')
    if [ -n "$jffs_usage" ] && [ "$jffs_usage" -gt 90 ]; then
        log_warn "/jffs is ${jffs_usage}% full! Listing large files:"
        du -ak /jffs 2>/dev/null | sort -nr | while read -r size path; do
            [ "$size" -gt 100 ] || break
            [ -f "$path" ] && printf '%6s KB  %s\n' "$size" "$path"
        done | head -20
        log_warn "Consider removing old backups or logs before proceeding."
    fi

    log_info "Removing SurfGate broken payload settings..."
    if grep -qE '^stealthsurf_(payload|staged_session|stage_)' /jffs/addons/custom_settings.txt 2>/dev/null; then
        custom_settings_drop '/^stealthsurf_payload/d;/^stealthsurf_staged_session/d;/^stealthsurf_stage_/d' || log_warn "Failed to remove broken payload settings"
    else
        log_info "No broken payload settings found."
    fi

    # Re-assert service hooks so Start/Stop from WebUI always reach SurfGate (/jffs/scripts/ssurf)
    setup_script_file "/jffs/scripts/service-event" "echo \"\$2\" | grep -q \"^stealthsurf\" && $ADDON_SCRIPT service_event \$(echo \"\$2\" | cut -d'_' -f2- | tr '_' ' ') & #ssurf" 2>/dev/null || true
    ensure_xray_scaffold 2>/dev/null || true

    log_info "Removing file $UI_RESPONSE_FILE..."
    rm -f "$UI_RESPONSE_FILE" || log_warn "Failed to remove $UI_RESPONSE_FILE"

    cleanup_stale_asdfiles

    log_ok "Done with fixme function."
}

urldecode() {
    local data
    data=$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/%\([0-9A-Fa-f][0-9A-Fa-f]\)/\\x\1/g')
    printf '%b' "$data"
}

jq_update_file() {
    local file="$1"
    local target
    shift
    if [ -L "$file" ] && target=$(readlink -f "$file") && [ -n "$target" ]; then
        file="$target"
    fi
    local tmp="$file.tmp.$$"
    if jq "$@" "$file" >"$tmp" 2>"$tmp.err" &&
        jq -n -e '[inputs] | length == 1 and (.[0] | type == "object")' "$tmp" >/dev/null 2>&1 &&
        mv -f "$tmp" "$file"; then
        rm -f "$tmp.err"
        return 0
    fi
    log_debug "jq_update_file: $file was left unchanged: $(head -c 300 "$tmp.err" 2>/dev/null)"
    rm -f "$tmp" "$tmp.err"
    return 1
}

xrayui_core_probe() {
    [ -n "$XRAYUI_CORE_VER_CACHE" ] && return 0
    local out rc bin
    XRAYUI_CORE_ERR=""
    out=$(xray version 2>&1)
    rc=$?
    XRAYUI_CORE_VER_CACHE=$(printf '%s\n' "$out" | grep -E '^Xray [0-9]+\.[0-9]+\.[0-9]+' | head -n 1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
    [ -n "$XRAYUI_CORE_VER_CACHE" ] && return 0
    XRAYUI_CORE_VER_CACHE="-"
    if [ "$rc" -eq 127 ]; then
        bin=$(which xray 2>/dev/null)
        if [ -z "$bin" ]; then
            XRAYUI_CORE_ERR="not installed"
        else
            XRAYUI_CORE_ERR="$bin cannot be executed (missing loader or interpreter)"
        fi
        return 0
    fi
    XRAYUI_CORE_ERR=$(printf '%s\n' "$out" | sed '/^[[:space:]]*$/d' | head -n 1 | cut -c1-200 | tr -d '<')
    case "$XRAYUI_CORE_ERR" in
    *": line "[01]": syntax error"*) XRAYUI_CORE_ERR="exec format error: the binary is not built for this router's CPU" ;;
    esac
    XRAYUI_CORE_ERR="${XRAYUI_CORE_ERR:-no version output, exit code $rc}"
}

xrayui_core_forget() {
    XRAYUI_CORE_VER_CACHE=""
    XRAYUI_CORE_ERR=""
}

xrayui_core_version() {
    xrayui_core_probe
    [ "$XRAYUI_CORE_VER_CACHE" = "-" ] || printf '%s' "$XRAYUI_CORE_VER_CACHE"
}

version_ge() {
    [ "$(printf '%s\n%s\n' "$2" "$1" | sort -t. -k1,1n -k2,2n -k3,3n | head -n1)" = "$2" ]
}

core_supports_allow_insecure() {
    local v
    v=$(xrayui_core_version)
    [ -z "$v" ] && return 1
    version_ge "$v" "26.3.27" && return 1
    return 0
}

# Xray 26.7.11 removed the unencrypted Shadowsocks ciphers (none/plain) and refuses to start with them.
core_supports_ss_plain_cipher() {
    local v
    v=$(xrayui_core_version)
    [ -z "$v" ] && return 1
    version_ge "$v" "26.7.11" && return 1
    return 0
}

get_or_create_hwid() {
    local hwid_file="$ADDON_SHARE_DIR/.hwid"
    if [ -f "$hwid_file" ]; then
        cat "$hwid_file"
        return
    fi
    local hwid=""
    if [ -f /proc/sys/kernel/random/uuid ]; then
        hwid=$(cat /proc/sys/kernel/random/uuid)
    else
        hwid=$(openssl rand -hex 16 | sed 's/\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)\(.\{12\}\)/\1-\2-\3-\4-\5/')
    fi
    printf '%s' "$hwid" >"$hwid_file"
    printf '%s' "$hwid"
}

cleanup_stale_asdfiles() {
    # Purge only StealthSurf staging / ASD leftovers — never stock xrayui_* backups.
    # /tmp is tmpfs on Merlin: leftover bodies from crashed curls eat RAM.
    local asdbk="/jffs/.asdbk"
    local f age now

    rm -f /tmp/stealthsurf_*.tmp.* 2>/dev/null
    rm -f /tmp/stealthsurf_dnsmasq_direct.tmp.* 2>/dev/null
    rm -f /tmp/stealthsurf_geoip4.* /tmp/stealthsurf_geoip6.* 2>/dev/null
    rm -f /tmp/stealthsurf_config.* /tmp/stealthsurf-dnsmasq-servers.* 2>/dev/null
    rm -f /tmp/stealthsurf_script.* /tmp/stealthsurf_payload* 2>/dev/null
    # Broader leftovers from subscriptions / failover / diag / tlsping / staging
    rm -f /tmp/stealthsurf_surl.* /tmp/stealthsurf_surl_dec.* /tmp/stealthsurf_pick.* 2>/dev/null
    rm -f /tmp/stealthsurf_proto_* /tmp/stealthsurf_fo_test.* /tmp/stealthsurf-tlsping.* 2>/dev/null
    rm -f /tmp/stealthsurf_diag_* /tmp/stealthsurf-tun-* /tmp/xray_api_ado.*.json 2>/dev/null
    rm -f /tmp/xray-response.*.tmp /tmp/xray-config-clean.json /tmp/custom_settings.* 2>/dev/null

    # Age-based purge of orphaned staging dirs and panel err dumps (keep live locks/logs)
    now=$(date +%s 2>/dev/null) || now=0
    if [ -d /tmp/stealthsurf-staging ] && [ "$now" -gt 0 ]; then
        for f in /tmp/stealthsurf-staging/*; do
            [ -e "$f" ] || continue
            age=$(date -r "$f" +%s 2>/dev/null) || age=0
            if [ "$age" -gt 0 ] && [ $((now - age)) -gt 120 ]; then
                rm -rf "$f" 2>/dev/null || true
            fi
        done
    fi
    if [ -d /tmp/ssurf ]; then
        for f in /tmp/ssurf/*.err /tmp/ssurf/*.tmp; do
            [ -e "$f" ] || continue
            age=$(date -r "$f" +%s 2>/dev/null) || age=0
            if [ "$age" -gt 0 ] && [ $((now - age)) -gt 300 ]; then
                rm -f "$f" 2>/dev/null || true
            fi
        done
    fi

    if [ -d "$asdbk" ]; then
        rm -f "$asdbk"/ssurf_*_bk "$asdbk"/*ssurf*.tmp.*_bk 2>/dev/null
        rm -f "$asdbk"/stealthsurf_*_bk "$asdbk"/*stealthsurf*.tmp.*_bk 2>/dev/null
    fi

}

# Kill processes whose cmdline contains our path (never bare killall by shared name)
ss_kill_by_cmdline_path() {
    local needle="$1"
    local sig="${2:--TERM}"
    local p cmd pid
    [ -n "$needle" ] || return 0
    for p in /proc/[0-9]*; do
        [ -r "$p/cmdline" ] || continue
        cmd=$(tr '\0' ' ' <"$p/cmdline" 2>/dev/null)
        case "$cmd" in
        *"$needle"*)
            pid=${p##*/}
            [ "$pid" = "$$" ] && continue
            kill "$sig" "$pid" 2>/dev/null || true
            ;;
        esac
    done
}

urldecode_pct() {
    s=$(printf '%s' "$1" | sed 's/\\/\\\\/g')
    s=$(printf '%s' "$s" | sed -e 's/%\([0-9A-Fa-f][0-9A-Fa-f]\)/\\x\1/g')
    printf '%b' "$s"
}

safe_preview() {
    dd bs=200 count=1 2>/dev/null | tr '\r\n' ' '
}

# Move Homavi88 SurfGate runtime from legacy tag "stealthsurf" → "ssurf".
# NEVER touches /jffs/addons/stealthsurf (official StealthSurf VPN).
migrate_homavi88_runtime_to_ssurf() {
    local src dst
    # Share / data
    if [ ! -d "$ADDON_SHARE_DIR" ] && [ -d /opt/share/stealthsurf ]; then
        mkdir -p "$(dirname "$ADDON_SHARE_DIR")" 2>/dev/null || true
        mv /opt/share/stealthsurf "$ADDON_SHARE_DIR" 2>/dev/null ||
            cp -a /opt/share/stealthsurf "$ADDON_SHARE_DIR" 2>/dev/null || true
        log_info "Migrated share data → $ADDON_SHARE_DIR"
    fi
    # Xray profile tree
    if [ ! -d "$XRAY_CONFIG_DIR" ] && [ -d /opt/etc/xray/stealthsurf ]; then
        mkdir -p "$(dirname "$XRAY_CONFIG_DIR")" 2>/dev/null || true
        mv /opt/etc/xray/stealthsurf "$XRAY_CONFIG_DIR" 2>/dev/null ||
            cp -a /opt/etc/xray/stealthsurf "$XRAY_CONFIG_DIR" 2>/dev/null || true
        log_info "Migrated Xray profiles → $XRAY_CONFIG_DIR"
    fi
    # Conf
    if [ ! -f "$XRAYUI_CONFIG_FILE" ] && [ -f /opt/etc/stealthsurf.conf ]; then
        cp -f /opt/etc/stealthsurf.conf "$XRAYUI_CONFIG_FILE" 2>/dev/null || true
        log_info "Migrated conf → $XRAYUI_CONFIG_FILE"
    fi
    # Merlin www user dir (Homavi88 panel JSON) — not official :8800 tree
    if [ ! -d "$ADDON_WEB_DIR" ] && [ -d /www/user/stealthsurf ]; then
        mkdir -p "$(dirname "$ADDON_WEB_DIR")" 2>/dev/null || true
        mv /www/user/stealthsurf "$ADDON_WEB_DIR" 2>/dev/null ||
            cp -a /www/user/stealthsurf "$ADDON_WEB_DIR" 2>/dev/null || true
        log_info "Migrated web dir → $ADDON_WEB_DIR"
    fi
    # Our old script path → ssurf (only if it looks like Homavi88 SurfGate)
    if [ -f /jffs/scripts/stealthsurf ] && [ ! -f "$ADDON_SCRIPT" ]; then
        if grep -q 'ADDON_TITLE="SurfGate"\|ADDON_PKG_NAME="ssurf"\|Homavi88' /jffs/scripts/stealthsurf 2>/dev/null; then
            mv /jffs/scripts/stealthsurf "$ADDON_SCRIPT" 2>/dev/null || true
            chmod 0755 "$ADDON_SCRIPT" 2>/dev/null || true
            log_info "Migrated script → $ADDON_SCRIPT"
        fi
    fi
    # Drop confusing /opt/bin/stealthsurf symlink (official branding); keep surfgate/ssurf
    if [ -L /opt/bin/stealthsurf ]; then
        case "$(readlink /opt/bin/stealthsurf 2>/dev/null)" in
        *ssurf* | *stealthsurf*)
            if [ -f /jffs/addons/ssurf/stealthsurf ] || [ -f "$ADDON_SCRIPT" ]; then
                rm -f /opt/bin/stealthsurf 2>/dev/null || true
            fi
            ;;
        esac
    fi
    # Custom geodata helper /opt/sbin/<tag>
    if [ -f /opt/sbin/stealthsurf ] && [ ! -e /opt/sbin/ssurf ]; then
        mv /opt/sbin/stealthsurf /opt/sbin/ssurf 2>/dev/null ||
            cp -f /opt/sbin/stealthsurf /opt/sbin/ssurf 2>/dev/null || true
    fi
    # Logrotate stanza rename
    if [ -f /opt/etc/logrotate.d/stealthsurf ] && [ ! -f /opt/etc/logrotate.d/ssurf ]; then
        mv /opt/etc/logrotate.d/stealthsurf /opt/etc/logrotate.d/ssurf 2>/dev/null ||
            cp -f /opt/etc/logrotate.d/stealthsurf /opt/etc/logrotate.d/ssurf 2>/dev/null || true
    fi
    # Temp / pid files
    mkdir -p /tmp/ssurf 2>/dev/null || true
    if [ -d /tmp/stealthsurf ] && [ ! -e /tmp/ssurf/panel.log ]; then
        cp -a /tmp/stealthsurf/. /tmp/ssurf/ 2>/dev/null || true
    fi
    # Flush legacy Homavi88 firewall chain names once (STEALTHSURF_* → SSURF_*)
    if type iptables >/dev/null 2>&1; then
        for ch in STEALTHSURF STEALTHSURF_DNS_LOCK STEALTHSURF_DNS_OWNERPROBE STEALTHSURF_DIVERT; do
            for tbl in filter mangle nat; do
                iptables -w -t "$tbl" -F "$ch" 2>/dev/null || true
                iptables -w -t "$tbl" -X "$ch" 2>/dev/null || true
                ip6tables -w -t "$tbl" -F "$ch" 2>/dev/null || true
                ip6tables -w -t "$tbl" -X "$ch" 2>/dev/null || true
            done
        done
        for s in STEALTHSURF_BYPASS4 STEALTHSURF_BYPASS6 STEALTHSURF_PROXY4 STEALTHSURF_PROXY6 \
            STEALTHSURF_BYPASS4_NET STEALTHSURF_BYPASS6_NET STEALTHSURF_PROXY4_NET STEALTHSURF_PROXY6_NET; do
            ipset destroy "$s" 2>/dev/null || ipset flush "$s" 2>/dev/null || true
        done
    fi
}

