#!/bin/sh
# shellcheck disable=SC2034  # codacy:Unused variables
#
# Standalone control panel (official StealthSurf analogy: lan_ip:8800).
# Ours listens on a dedicated router IP:port — default lan_ip:1131 — so it can
# sit next to the stock StealthSurf panel on :8800 without sharing Merlin's ASP UI.

PANEL_DEFAULT_PORT=1131
PANEL_PIDFILE=/var/run/stealthsurf-panel.pid
PANEL_LOG=/tmp/stealthsurf/panel.log
PANEL_HTTPD_CONF="$ADDON_JFFS_ADN_DIR/panel/httpd.conf"
PANEL_WEB_ROOT="$ADDON_JFFS_ADN_DIR/panel"
PANEL_CGI_DIR="$PANEL_WEB_ROOT/cgi-bin"
PANEL_SECONDARY_TAG="stealthsurf-panel"

panel_load_settings() {
    load_xrayui_config 2>/dev/null || true

    PANEL_PORT="${panel_port:-$PANEL_DEFAULT_PORT}"
    case "$PANEL_PORT" in
    '' | *[!0-9]*) PANEL_PORT=$PANEL_DEFAULT_PORT ;;
    esac
    if [ "$PANEL_PORT" -lt 1 ] || [ "$PANEL_PORT" -gt 65535 ]; then
        PANEL_PORT=$PANEL_DEFAULT_PORT
    fi

    PANEL_LAN_IP=$(nvram get lan_ipaddr 2>/dev/null)
    [ -n "$PANEL_LAN_IP" ] || PANEL_LAN_IP="192.168.50.1"

    # Optional dedicated/secondary IPv4 on the LAN bridge (br0). When set and
    # different from lan_ipaddr, we add an alias and bind the panel only there.
    PANEL_IP="${panel_ip:-}"
    if [ -z "$PANEL_IP" ]; then
        PANEL_IP=$PANEL_LAN_IP
        PANEL_USE_SECONDARY=0
    elif [ "$PANEL_IP" = "$PANEL_LAN_IP" ]; then
        PANEL_USE_SECONDARY=0
    else
        PANEL_USE_SECONDARY=1
    fi

    PANEL_BIND="${panel_bind:-$PANEL_IP}"
    PANEL_IFACE="${panel_iface:-br0}"
}

# True when $1 (busybox binary) actually includes the httpd applet.
# Firmware BusyBox on Merlin often omits httpd; Entware busybox usually has it.
panel_busybox_has_httpd() {
    local bb="$1"
    [ -n "$bb" ] || return 1
    if [ "$bb" = "busybox" ]; then
        command -v busybox >/dev/null 2>&1 || return 1
    else
        [ -x "$bb" ] || return 1
    fi

    # Applet list in banner (most builds)
    if "$bb" 2>&1 | grep -Eq '(^|[[:space:]])httpd([[:space:]]|$)'; then
        return 0
    fi

    # Probe invoke: missing applet → "applet not found"; present → usage/help
    local err
    err=$("$bb" httpd 2>&1) || true
    case "$err" in
    *applet\ not\ found* | *Unknown\ applet* | *unknown\ applet*)
        return 1
        ;;
    esac
    # Empty output with failure is inconclusive — require a hint of httpd usage
    case "$err" in
    *[Hh]ttpd* | *Usage:* | *-p\ * | *-h\ *)
        return 0
        ;;
    esac
    return 1
}

# Bundled static panel-httpd from the package (works offline; no opkg).
panel_bundled_httpd() {
    local arch bin
    arch=$(uname -m 2>/dev/null || echo unknown)
    case "$arch" in
    aarch64 | arm64)
        bin="$ADDON_JFFS_ADN_DIR/bin/panel-httpd.aarch64"
        ;;
    armv7* | armv6* | armv5* | arm)
        bin="$ADDON_JFFS_ADN_DIR/bin/panel-httpd.armv7"
        ;;
    *)
        return 1
        ;;
    esac
    [ -f "$bin" ] || return 1
    chmod 0755 "$bin" 2>/dev/null || true
    [ -x "$bin" ] || return 1
    echo "$bin"
}

panel_find_busybox_httpd() {
    # Entware/firmware BusyBox — never the stock Asus /usr/sbin/httpd.
    local cand
    for cand in /opt/bin/busybox busybox /bin/busybox /sbin/busybox; do
        panel_busybox_has_httpd "$cand" || continue
        echo "$cand httpd"
        return 0
    done
    return 1
}

# Back-compat name used by older callers/tests.
panel_find_httpd() {
    panel_find_busybox_httpd
}

panel_find_lighttpd() {
    local cand
    for cand in /opt/sbin/lighttpd /opt/bin/lighttpd; do
        [ -x "$cand" ] || continue
        echo "$cand"
        return 0
    done
    return 1
}

panel_opkg_install() {
    # $@ = packages; best-effort when feeds are reachable
    [ -x /opt/bin/opkg ] || return 1
    opkg update >>"$PANEL_LOG" 2>&1 || log_warn "panel: opkg update failed; trying install anyway"
    opkg install "$@" >>"$PANEL_LOG" 2>&1
}

# Ensure a usable panel web server. Prefer bundled binary (no network/opkg).
panel_ensure_httpd() {
    mkdir -p /tmp/stealthsurf 2>/dev/null || true
    if panel_bundled_httpd >/dev/null 2>&1; then
        return 0
    fi
    if panel_find_busybox_httpd >/dev/null 2>&1 || panel_find_lighttpd >/dev/null 2>&1; then
        return 0
    fi

    # Optional: try Entware if feeds work (often fail on routers without WAN DNS).
    if [ -x /opt/bin/opkg ]; then
        log_warn "panel: no bundled/BusyBox httpd — trying Entware lighttpd once..."
        printf '%s\n' "==> opkg install lighttpd lighttpd-mod-cgi lighttpd-mod-alias" >>"$PANEL_LOG"
        panel_opkg_install lighttpd lighttpd-mod-cgi lighttpd-mod-alias || true
        if panel_find_lighttpd >/dev/null 2>&1; then
            log_ok "panel: Entware lighttpd is available"
            return 0
        fi
    fi

    log_error "panel: no web server (bundled panel-httpd missing for $(uname -m 2>/dev/null))"
    printf '%s\n' "No panel-httpd binary for this arch; opkg lighttpd unavailable." >>"$PANEL_LOG"
    return 1
}

panel_write_lighttpd_conf() {
    # $1 = bind IP (empty = all interfaces)
    local bind_ip="$1"
    local conf="$PANEL_WEB_ROOT/lighttpd.conf"
    {
        echo 'server.modules = ( "mod_alias", "mod_cgi" )'
        echo "server.document-root = \"$PANEL_WEB_ROOT\""
        echo "server.port = $PANEL_PORT"
        if [ -n "$bind_ip" ]; then
            echo "server.bind = \"$bind_ip\""
        fi
        echo 'server.pid-file = "'"$PANEL_PIDFILE"'"'
        echo 'server.errorlog = "'"$PANEL_LOG"'"'
        echo 'index-file.names = ( "index.html" )'
        echo 'mimetype.assign = ( ".html" => "text/html", ".js" => "application/javascript", ".json" => "application/json", ".css" => "text/css", ".svg" => "image/svg+xml", ".png" => "image/png", ".ico" => "image/x-icon" )'
        # Extensionless CGI scripts under /cgi-bin/ (no PCRE url =~ needed)
        echo "alias.url = ( \"/cgi-bin/\" => \"$PANEL_CGI_DIR/\" )"
        echo 'cgi.assign = ( "" => "" )'
    } >"$conf"
    echo "$conf"
}

panel_ensure_secondary_ip() {
    panel_load_settings
    [ "$PANEL_USE_SECONDARY" = "1" ] || return 0

    if ! ip -4 addr show dev "$PANEL_IFACE" 2>/dev/null | grep -q "inet ${PANEL_IP}/"; then
        local mask
        mask=$(nvram get lan_netmask 2>/dev/null)
        [ -n "$mask" ] || mask="255.255.255.0"
        local prefix
        prefix=$(panel_netmask_to_prefix "$mask")
        log_info "Adding secondary panel IP ${PANEL_IP}/${prefix} on $PANEL_IFACE"
        ip addr add "${PANEL_IP}/${prefix}" dev "$PANEL_IFACE" label "${PANEL_IFACE}:${PANEL_SECONDARY_TAG}" 2>/dev/null ||
            ip addr add "${PANEL_IP}/${prefix}" dev "$PANEL_IFACE" 2>/dev/null ||
            log_warn "Could not add secondary IP $PANEL_IP on $PANEL_IFACE"
    fi
}

panel_remove_secondary_ip() {
    panel_load_settings
    [ "$PANEL_USE_SECONDARY" = "1" ] || return 0
    ip addr del "${PANEL_IP}/32" dev "$PANEL_IFACE" 2>/dev/null || true
    # Try common prefix lengths if /32 was not how it was added
    local mask prefix
    mask=$(nvram get lan_netmask 2>/dev/null)
    [ -n "$mask" ] || mask="255.255.255.0"
    prefix=$(panel_netmask_to_prefix "$mask")
    ip addr del "${PANEL_IP}/${prefix}" dev "$PANEL_IFACE" 2>/dev/null || true
}

panel_netmask_to_prefix() {
    # BusyBox-friendly dotted → CIDR for common LAN masks
    case "$1" in
    255.255.255.0) echo 24 ;;
    255.255.0.0) echo 16 ;;
    255.0.0.0) echo 8 ;;
    255.255.255.128) echo 25 ;;
    255.255.255.192) echo 26 ;;
    255.255.255.224) echo 27 ;;
    255.255.255.240) echo 28 ;;
    *) echo 24 ;;
    esac
}

panel_write_cgi() {
    mkdir -p "$PANEL_CGI_DIR" || return 1

    # BusyBox/lighttpd CGI fallback. Bundled panel-httpd (1.4.8+) calls the addon
    # directly via /bin/sh and does not depend on these scripts being +x/exec.
    # Always invoke addon with /bin/sh (works when script lacks +x).
    cat >"$PANEL_CGI_DIR/bootstrap" <<'CGI'
#!/bin/sh
echo "Content-Type: application/json"
echo "Cache-Control: no-store"
echo ""
export PATH="/opt/bin:/opt/sbin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
ADDON_SCRIPT="${ADDON_SCRIPT:-/jffs/scripts/stealthsurf}"
if [ -f "$ADDON_SCRIPT" ]; then
  /bin/sh "$ADDON_SCRIPT" panel bootstrap 2>/tmp/stealthsurf/cgi-bootstrap.err
else
  echo '{"ok":false,"error":"stealthsurf missing"}'
fi
CGI

    cat >"$PANEL_CGI_DIR/api" <<'CGI'
#!/bin/sh
echo "Content-Type: application/json"
echo "Cache-Control: no-store"
echo ""
export PATH="/opt/bin:/opt/sbin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
ADDON_SCRIPT="${ADDON_SCRIPT:-/jffs/scripts/stealthsurf}"
export CONTENT_LENGTH REQUEST_METHOD
if [ -f "$ADDON_SCRIPT" ]; then
  /bin/sh "$ADDON_SCRIPT" panel api 2>/tmp/stealthsurf/cgi-api.err
else
  echo '{"ok":false,"error":"stealthsurf missing"}'
fi
CGI

    cat >"$PANEL_CGI_DIR/status" <<'CGI'
#!/bin/sh
echo "Content-Type: application/json"
echo "Cache-Control: no-store"
echo ""
export PATH="/opt/bin:/opt/sbin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
ADDON_SCRIPT="${ADDON_SCRIPT:-/jffs/scripts/stealthsurf}"
if [ -f "$ADDON_SCRIPT" ]; then
  /bin/sh "$ADDON_SCRIPT" panel live 2>/tmp/stealthsurf/cgi-status.err
else
  echo '{"ok":false,"error":"stealthsurf missing"}'
fi
CGI

    chmod 0755 "$PANEL_CGI_DIR/bootstrap" "$PANEL_CGI_DIR/api" "$PANEL_CGI_DIR/status" || true
}

panel_prepare_webroot() {
    panel_load_settings
    mkdir -p "$PANEL_WEB_ROOT/ext/stealthsurf" "$PANEL_CGI_DIR" /tmp/stealthsurf || return 1

    # Static SPA
    if [ -f "$ADDON_JFFS_ADN_DIR/panel/index.html" ]; then
        :
    elif [ -f "$ADDON_JFFS_ADN_DIR/index.panel.html" ]; then
        cp -f "$ADDON_JFFS_ADN_DIR/index.panel.html" "$PANEL_WEB_ROOT/index.html"
    fi

    # Prefer panel-local app.js; fall back to shared addon copy
    if [ ! -f "$PANEL_WEB_ROOT/app.js" ] && [ -f "$ADDON_JFFS_ADN_DIR/app.js" ]; then
        ln -s -f "$ADDON_JFFS_ADN_DIR/app.js" "$PANEL_WEB_ROOT/app.js"
    fi

    # Same JSON/cab surface the Merlin UI uses under /ext/stealthsurf/
    if [ -d "$ADDON_WEB_DIR" ]; then
        ln -sfn "$ADDON_WEB_DIR" "$PANEL_WEB_ROOT/ext/stealthsurf-files" 2>/dev/null || true
        # BusyBox httpd does not follow a directory symlink as document root child
        # reliably on all builds — mirror individual files as symlinks.
        local f
        for f in "$ADDON_WEB_DIR"/*; do
            [ -e "$f" ] || continue
            ln -s -f "$f" "$PANEL_WEB_ROOT/ext/stealthsurf/${f##*/}" 2>/dev/null || true
        done
    fi

    panel_write_cgi

    # BusyBox httpd.conf: optional Basic auth when panel_password_hash is set.
    # Auth line format: /:user:encrypted
    {
        echo "I:index.html"
        if [ -n "${panel_password_hash:-}" ]; then
            echo "/:${panel_user:-admin}:${panel_password_hash}"
        fi
    } >"$PANEL_HTTPD_CONF"

    # BusyBox runs any executable under cgi-bin/ as CGI.
    chmod 0755 "$PANEL_CGI_DIR"/* 2>/dev/null || true
}

panel_url() {
    panel_load_settings
    echo "http://${PANEL_BIND}:${PANEL_PORT}/"
}

panel_is_running() {
    local pid
    pid=$(cat "$PANEL_PIDFILE" 2>/dev/null) || return 1
    case "$pid" in
    '' | *[!0-9]*) return 1 ;;
    esac
    kill -0 "$pid" 2>/dev/null || return 1
    # Confirm it is our panel server (bundled panel-httpd, BusyBox httpd, or lighttpd)
    if [ -r "/proc/$pid/cmdline" ]; then
        tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null | grep -q "stealthsurf/panel\|panel-httpd\|:${PANEL_PORT}\| $PANEL_PORT \|lighttpd.conf" || {
            tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null | grep -qiE 'httpd|lighttpd|panel-httpd' || return 1
        }
    fi
    return 0
}

panel_stop() {
    panel_load_settings
    if [ -f "$PANEL_PIDFILE" ]; then
        local pid
        pid=$(cat "$PANEL_PIDFILE" 2>/dev/null)
        if [ -n "$pid" ]; then
            kill "$pid" 2>/dev/null || true
            local i=0
            while [ "$i" -lt 20 ] && kill -0 "$pid" 2>/dev/null; do
                sleep 1
                i=$((i + 1))
            done
            kill -9 "$pid" 2>/dev/null || true
        fi
        rm -f "$PANEL_PIDFILE"
    fi
    # Strays bound to our port
    if type netstat >/dev/null 2>&1; then
        local p
        for p in $(netstat -lntp 2>/dev/null | awk -v port=":$PANEL_PORT" '$4 ~ port { split($7,a,"/"); print a[1] }'); do
            case "$p" in
            '' | *[!0-9]* | 1) ;;
            *) kill "$p" 2>/dev/null || true ;;
            esac
        done
    fi
    log_info "Standalone panel stopped"
}

panel_start_bundled_once() {
    # $1 = listen addr (IP:PORT or :PORT); $2 = panel-httpd binary
    local listen_arg="$1"
    local bin="$2"
    # -addon: call stealthsurf via /bin/sh (no CGI shebang on /jffs → no HTTP 500 on noexec/+x)
    "$bin" -root "$PANEL_WEB_ROOT" -listen "$listen_arg" -addon "${ADDON_SCRIPT:-/jffs/scripts/stealthsurf}" >>"$PANEL_LOG" 2>&1 &
    echo $! >"$PANEL_PIDFILE"
    sleep 1
    panel_is_running
}

panel_start_busybox_once() {
    # $1 = bind arg for -p (IP:PORT or PORT); $2 = "busybox httpd" command
    local bind_arg="$1"
    local httpd_cmd="$2"

    # -c is relative to -h on some BusyBox builds; conf lives in PANEL_WEB_ROOT.
    # shellcheck disable=SC2086
    $httpd_cmd -p "$bind_arg" -h "$PANEL_WEB_ROOT" -c httpd.conf >>"$PANEL_LOG" 2>&1 &
    echo $! >"$PANEL_PIDFILE"
    sleep 1
    panel_is_running
}

panel_start_lighttpd_once() {
    # $1 = bind IP (empty = all interfaces); $2 = lighttpd binary
    local bind_ip="$1"
    local bin="$2"
    local conf
    conf=$(panel_write_lighttpd_conf "$bind_ip")
    # -D: stay in foreground so $! is the real server PID
    "$bin" -f "$conf" -D >>"$PANEL_LOG" 2>&1 &
    echo $! >"$PANEL_PIDFILE"
    sleep 1
    panel_is_running
}

panel_mark_started() {
    log_ok "Standalone panel listening on $(panel_url)"
    am_settings_set stealthsurf_panel_url "$(panel_url)" 2>/dev/null || true
}

panel_start() {
    panel_load_settings
    mkdir -p /tmp/stealthsurf
    : >"$PANEL_LOG"

    panel_prepare_webroot || {
        log_error "panel: failed to prepare web root"
        return 1
    }
    panel_ensure_secondary_ip

    if panel_is_running; then
        log_info "Standalone panel already running on $(panel_url)"
        return 0
    fi

    panel_ensure_httpd || {
        log_error "panel: no web server. Reinstall 1.4.7+ package (includes bin/panel-httpd) or: opkg install lighttpd lighttpd-mod-cgi lighttpd-mod-alias"
        return 1
    }

    local bundled httpd_cmd lighttpd_bin
    bundled=$(panel_bundled_httpd 2>/dev/null) || bundled=""
    httpd_cmd=$(panel_find_busybox_httpd 2>/dev/null) || httpd_cmd=""
    lighttpd_bin=$(panel_find_lighttpd 2>/dev/null) || lighttpd_bin=""

    # 1) Bundled static panel-httpd (preferred — no opkg)
    if [ -n "$bundled" ]; then
        printf '%s\n' "==> starting bundled: $bundled -listen ${PANEL_BIND}:${PANEL_PORT}" >>"$PANEL_LOG"
        if panel_start_bundled_once "${PANEL_BIND}:${PANEL_PORT}" "$bundled"; then
            panel_mark_started
            return 0
        fi
        printf '%s\n' "==> bind ${PANEL_BIND}:${PANEL_PORT} failed; retry :${PANEL_PORT}" >>"$PANEL_LOG"
        rm -f "$PANEL_PIDFILE"
        if panel_start_bundled_once ":${PANEL_PORT}" "$bundled"; then
            panel_mark_started
            return 0
        fi
        rm -f "$PANEL_PIDFILE"
    fi

    # 2) BusyBox httpd applet
    if [ -n "$httpd_cmd" ]; then
        printf '%s\n' "==> starting busybox: $httpd_cmd -p ${PANEL_BIND}:${PANEL_PORT}" >>"$PANEL_LOG"
        if panel_start_busybox_once "${PANEL_BIND}:${PANEL_PORT}" "$httpd_cmd"; then
            panel_mark_started
            return 0
        fi
        printf '%s\n' "==> bind ${PANEL_BIND}:${PANEL_PORT} failed; retry -p ${PANEL_PORT}" >>"$PANEL_LOG"
        rm -f "$PANEL_PIDFILE"
        if panel_start_busybox_once "$PANEL_PORT" "$httpd_cmd"; then
            panel_mark_started
            return 0
        fi
        rm -f "$PANEL_PIDFILE"
    fi

    # 3) Entware lighttpd
    if [ -n "$lighttpd_bin" ]; then
        printf '%s\n' "==> starting lighttpd: $lighttpd_bin (bind $PANEL_BIND)" >>"$PANEL_LOG"
        if panel_start_lighttpd_once "$PANEL_BIND" "$lighttpd_bin"; then
            panel_mark_started
            return 0
        fi
        printf '%s\n' "==> lighttpd bind $PANEL_BIND failed; retry all interfaces" >>"$PANEL_LOG"
        rm -f "$PANEL_PIDFILE"
        if panel_start_lighttpd_once "" "$lighttpd_bin"; then
            panel_mark_started
            return 0
        fi
        rm -f "$PANEL_PIDFILE"
    fi

    log_error "panel: failed to start web server (see $PANEL_LOG)"
    if [ -s "$PANEL_LOG" ]; then
        log_error "panel.log: $(tr '\n' ' ' <"$PANEL_LOG" | cut -c1-240)"
    fi
    return 1
}

panel_restart() {
    panel_stop
    panel_start
}

panel_status() {
    panel_load_settings
    if panel_is_running; then
        echo "panel: running  $(panel_url)  pid=$(cat "$PANEL_PIDFILE" 2>/dev/null)"
        return 0
    fi
    echo "panel: stopped  (would listen on $(panel_url))"
    return 1
}

# JSON bootstrap for the SPA (replaces Merlin ASP <% nvram_get %> blocks).
panel_bootstrap_json() {
    # Keep stdout clean for CGI/panel-httpd JSON (logs → stderr only).
    {
        panel_load_settings
        load_xrayui_config 2>/dev/null || true
    } 1>&2

    local productid firmver lang territory wan_ip link_internet rc_support extendno
    productid=$(nvram get productid 2>/dev/null)
    firmver=$(nvram get firmver 2>/dev/null)
    lang=$(nvram get preferred_lang 2>/dev/null)
    [ -n "$lang" ] || lang="en"
    territory=$(nvram get territory_code 2>/dev/null)
    wan_ip=$(nvram get wan_ipaddr 2>/dev/null)
    link_internet=$(nvram get link_internet 2>/dev/null)
    rc_support=$(nvram get rc_support 2>/dev/null)
    extendno=$(nvram get extendno 2>/dev/null)

    local wan_connected=false
    [ "$link_internet" = "2" ] && wan_connected=true

    local is_gnuton=false
    case "$extendno" in
    *gnuton*) is_gnuton=true ;;
    esac

    local xray_running=false
    if [ -n "$(get_xray_daemon_pid 2>/dev/null)" ]; then
        xray_running=true
    fi

    local b4sni_running=false
    if pidof b4sni >/dev/null 2>&1; then
        b4sni_running=true
    fi

    local cpu
    cpu=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null) || cpu=1
    case "$cpu" in '' | *[!0-9]*) cpu=1 ;; esac

    local custom_settings="{}"
    if [ -f /jffs/addons/custom_settings.txt ]; then
        custom_settings=$(
            awk -F= '
              BEGIN { printf "{" }
              /^stealthsurf_/ {
                key=$1
                val=substr($0, index($0,"=")+1)
                gsub(/\\/,"\\\\",val); gsub(/"/,"\\\"",val); gsub(/\r/,"",val)
                if (n++) printf ","
                printf "\"%s\":\"%s\"", key, val
              }
              END { printf "}" }
            ' /jffs/addons/custom_settings.txt 2>/dev/null
        )
        [ -n "$custom_settings" ] || custom_settings="{}"
        # Validate JSON — corrupt custom_settings.txt must not break --argjson
        printf '%s' "$custom_settings" | jq -e . >/dev/null 2>&1 || custom_settings="{}"
    fi
    # Prefer live NVRAM for boot-autostart so the UI matches what startup() will do.
    # Empty/invalid → enabled (same default as install).
    local ss_startup
    ss_startup=$(am_settings_get stealthsurf_startup 2>/dev/null || true)
    case "$ss_startup" in
    y | n) ;;
    *) ss_startup="y" ;;
    esac
    custom_settings=$(printf '%s' "$custom_settings" | jq -c --arg v "$ss_startup" '.stealthsurf_startup = $v' 2>/dev/null) ||
        custom_settings=$(printf '{"stealthsurf_startup":"%s"}' "$ss_startup")

    # Devices: best-effort empty objects (full client DB stays on Merlin ASP path)
    jq -nc \
        --arg name "$productid" \
        --arg firmware "$firmver" \
        --arg language "$lang" \
        --arg ip "$PANEL_LAN_IP" \
        --arg panel_ip "$PANEL_IP" \
        --argjson panel_port "$PANEL_PORT" \
        --arg territory "$territory" \
        --arg wan_ip "$wan_ip" \
        --argjson wan_connected "$wan_connected" \
        --arg features "$rc_support" \
        --argjson is_gnuton "$is_gnuton" \
        --argjson isRunning "$xray_running" \
        --argjson b4sni_isRunning "$b4sni_running" \
        --argjson cpu "$cpu" \
        --argjson custom_settings "$custom_settings" \
        '{
          ok: true,
          standalone: true,
          panel: { url: ("http://" + $panel_ip + ":" + ($panel_port|tostring) + "/"), ip: $panel_ip, port: $panel_port },
          xray: {
            router: {
              name: $name,
              firmware: $firmware,
              language: $language,
              ip: $ip,
              territory: $territory,
              wan_ip: $wan_ip,
              wan_connected: $wan_connected,
              features: $features,
              is_gnuton: $is_gnuton,
              cpu: $cpu,
              devices_online: {},
              devices: {}
            },
            server: { isRunning: $isRunning, b4sni_isRunning: $b4sni_isRunning },
            custom_settings: $custom_settings
          }
        }' 2>/dev/null || echo '{"ok":false,"error":"jq failed"}'
}

# Live dashboard metrics for the light panel (CPU / RAM / traffic counters).
panel_live_json() {
    panel_load_settings
    load_xrayui_config 2>/dev/null || true

    local running=false pid=0
    pid=$(get_xray_daemon_pid 2>/dev/null) || pid=0
    case "$pid" in
    '' | *[!0-9]*) pid=0 ;;
    esac
    [ "$pid" -gt 0 ] && running=true

    local cpu_pct=0
    # BusyBox-friendly one-shot CPU estimate from /proc/stat idle ratio.
    cpu_pct=$(
        awk '
      NR==1 {
        idle=$5; total=0
        for (i=2;i<=NF;i++) total+=$i
        getline < "/dev/null"
      }
      END {
        # Fallback: read again after short sleep via shell; here use loadavg heuristic
        print 0
      }' /proc/stat 2>/dev/null
    )
    # Prefer loadavg-based estimate (works without sleep on BusyBox)
    cpu_pct=$(
        awk -v n="$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1)" '
      {
        load=$1+0
        if (n < 1) n=1
        pct=int((load / n) * 100 + 0.5)
        if (pct < 0) pct=0
        if (pct > 100) pct=100
        print pct
        exit
      }' /proc/loadavg 2>/dev/null
    )
    case "$cpu_pct" in '' | *[!0-9]*) cpu_pct=0 ;; esac

    local mem_total_kb=0 mem_avail_kb=0 mem_used_mb=0 mem_total_mb=0
    mem_total_kb=$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null)
    mem_avail_kb=$(awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo 2>/dev/null)
    [ -n "$mem_avail_kb" ] || mem_avail_kb=$(awk '/^MemFree:/ {print $2; exit}' /proc/meminfo 2>/dev/null)
    case "$mem_total_kb" in '' | *[!0-9]*) mem_total_kb=0 ;; esac
    case "$mem_avail_kb" in '' | *[!0-9]*) mem_avail_kb=0 ;; esac
    if [ "$mem_total_kb" -gt 0 ]; then
        mem_total_mb=$((mem_total_kb / 1024))
        mem_used_mb=$(((mem_total_kb - mem_avail_kb) / 1024))
        [ "$mem_used_mb" -ge 0 ] || mem_used_mb=0
    fi

    local app_rss_mb=0
    if [ "$pid" -gt 0 ] && [ -r "/proc/$pid/status" ]; then
        app_rss_mb=$(awk '/^VmRSS:/ {print int($2/1024); exit}' "/proc/$pid/status" 2>/dev/null)
        case "$app_rss_mb" in '' | *[!0-9]*) app_rss_mb=0 ;; esac
    fi

    local wan_ip
    wan_ip=$(nvram get wan_ipaddr 2>/dev/null)

    local vpn_up=0 vpn_down=0 direct_up=0 direct_down=0
    # Best-effort cumulative counters from last xray stats snapshot (bytes).
    if [ -f "$ADDON_SHARE_DIR/xray_stats.json" ]; then
        # startswith/endswith — no ONIGURUMA regex needed
        vpn_up=$(jq -r '[.stat[]? | select((.name // "") | startswith("outbound>>>ss-") and endswith(">>>traffic>>>uplink")) | (.value // 0|tonumber)] | add // 0' "$ADDON_SHARE_DIR/xray_stats.json" 2>/dev/null)
        vpn_down=$(jq -r '[.stat[]? | select((.name // "") | startswith("outbound>>>ss-") and endswith(">>>traffic>>>downlink")) | (.value // 0|tonumber)] | add // 0' "$ADDON_SHARE_DIR/xray_stats.json" 2>/dev/null)
        direct_up=$(jq -r '[.stat[]? | select((.name // "") | startswith("outbound>>>direct>>>") and endswith(">>>traffic>>>uplink")) | (.value // 0|tonumber)] | add // 0' "$ADDON_SHARE_DIR/xray_stats.json" 2>/dev/null)
        direct_down=$(jq -r '[.stat[]? | select((.name // "") | startswith("outbound>>>direct>>>") and endswith(">>>traffic>>>downlink")) | (.value // 0|tonumber)] | add // 0' "$ADDON_SHARE_DIR/xray_stats.json" 2>/dev/null)
    fi
    case "$vpn_up" in '' | *[!0-9]*) vpn_up=0 ;; esac
    case "$vpn_down" in '' | *[!0-9]*) vpn_down=0 ;; esac
    case "$direct_up" in '' | *[!0-9]*) direct_up=0 ;; esac
    case "$direct_down" in '' | *[!0-9]*) direct_down=0 ;; esac

    # Refresh stats asynchronously so next poll is fresher (ignore errors).
    if [ "$running" = true ] && type api_get_connection_status >/dev/null 2>&1; then
        (api_get_connection_status >/dev/null 2>&1 &) || true
    fi

    local ts
    ts=$(date +%s 2>/dev/null) || ts=0

    jq -nc \
        --argjson ok true \
        --argjson running "$running" \
        --argjson pid "$pid" \
        --argjson cpu_pct "$cpu_pct" \
        --argjson mem_used_mb "$mem_used_mb" \
        --argjson mem_total_mb "$mem_total_mb" \
        --argjson app_rss_mb "$app_rss_mb" \
        --arg wan_ip "$wan_ip" \
        --argjson vpn_up "$vpn_up" \
        --argjson vpn_down "$vpn_down" \
        --argjson direct_up "$direct_up" \
        --argjson direct_down "$direct_down" \
        --argjson ts "$ts" \
        '{
          ok: $ok,
          running: $running,
          pid: $pid,
          cpu_pct: $cpu_pct,
          mem_used_mb: $mem_used_mb,
          mem_total_mb: $mem_total_mb,
          app_rss_mb: $app_rss_mb,
          wan_ip: $wan_ip,
          traffic: {
            vpn_up: $vpn_up,
            vpn_down: $vpn_down,
            direct_up: $direct_up,
            direct_down: $direct_down
          },
          ts: $ts
        }' 2>/dev/null || echo '{"ok":false,"error":"jq failed"}'
}

# Accept POST JSON: { "action": "stealthsurf_…", "settings": { … } }
panel_api_handle() {
    local body=""
    if [ "${REQUEST_METHOD:-GET}" = "POST" ]; then
        if [ -n "${CONTENT_LENGTH:-}" ]; then
            body=$(dd bs=1 count="$CONTENT_LENGTH" 2>/dev/null)
        else
            body=$(cat)
        fi
    fi

    if [ -z "$body" ]; then
        echo '{"ok":false,"error":"empty body"}'
        return 1
    fi

    local action settings
    action=$(printf '%s' "$body" | jq -r '.action // empty' 2>/dev/null)
    settings=$(printf '%s' "$body" | jq -c '.settings // {}' 2>/dev/null)

    case "$action" in
    stealthsurf_*) ;;
    *)
        echo '{"ok":false,"error":"invalid action"}'
        return 1
        ;;
    esac

    # Apply stealthsurf_* settings (payload chunks etc.) like Merlin amng_custom.
    # Drop leftover payload/stage keys first when a new payload arrives — otherwise a
    # shorter chunk set concatenates with stale payload1+ and corrupts reconstruct_payload.
    if [ -n "$settings" ] && [ "$settings" != "{}" ] && [ "$settings" != "null" ]; then
        if printf '%s' "$settings" | jq -e 'keys[] | select(startswith("stealthsurf_payload") or startswith("stealthsurf_stage") or . == "stealthsurf_staged_session")' >/dev/null 2>&1; then
            cleanup_payload 2>/dev/null || true
            custom_settings_drop '/^stealthsurf_staged_session/d;/^stealthsurf_stage_/d' 2>/dev/null || true
        fi
        printf '%s' "$settings" | jq -r 'to_entries[] | select(.key|startswith("stealthsurf_")) | "\(.key)\t\(.value|tostring)"' 2>/dev/null |
            while IFS=$(printf '\t') read -r key val; do
                [ -n "$key" ] || continue
                am_settings_set "$key" "$val" 2>/dev/null || true
            done
    fi

    # Map stealthsurf_configuration_apply → service_event configuration apply
    local rest
    rest=$(printf '%s' "$action" | cut -d'_' -f2- | tr '_' ' ')
    /jffs/scripts/stealthsurf service_event $rest >/tmp/stealthsurf/panel-api.log 2>&1 &

    echo '{"ok":true,"queued":true,"action":"'"$action"'"}'
}

panel_set_password() {
    # Usage: panel set-password  (reads password from stdin, one line)
    panel_load_settings
    local password
    IFS= read -r password || true
    local len=${#password}
    if [ "$len" -lt 8 ] || [ "$len" -gt 128 ]; then
        echo "Password must be 8–128 characters" >&2
        return 1
    fi
    local hash user
    user="${panel_user:-admin}"
    if type openssl >/dev/null 2>&1; then
        hash=$(openssl passwd -1 "$password" 2>/dev/null)
    elif type mkpasswd >/dev/null 2>&1; then
        hash=$(mkpasswd -m md5crypt "$password" 2>/dev/null)
    else
        echo "openssl or mkpasswd required to hash the panel password" >&2
        return 1
    fi
    [ -n "$hash" ] || {
        echo "Failed to hash password" >&2
        return 1
    }

    # Persist into stealthsurf.conf
    touch "$XRAYUI_CONFIG_FILE" 2>/dev/null || true
    if grep -q '^panel_password_hash=' "$XRAYUI_CONFIG_FILE" 2>/dev/null; then
        sed -i "s|^panel_password_hash=.*|panel_password_hash=$hash|" "$XRAYUI_CONFIG_FILE"
    else
        echo "panel_password_hash=$hash" >>"$XRAYUI_CONFIG_FILE"
    fi
    if grep -q '^panel_user=' "$XRAYUI_CONFIG_FILE" 2>/dev/null; then
        sed -i "s|^panel_user=.*|panel_user=$user|" "$XRAYUI_CONFIG_FILE"
    else
        echo "panel_user=$user" >>"$XRAYUI_CONFIG_FILE"
    fi
    panel_restart
    echo "Panel password saved for user '$user'. Open $(panel_url)"
}
