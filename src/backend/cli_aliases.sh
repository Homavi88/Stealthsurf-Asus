#!/bin/sh
# shellcheck disable=SC2034
# Short CLI aliases (ssurf …) for StealthSurf 1.1.x

ss_cli_echo() {
    printf '%s\n' "$*"
}

ss_cli_ensure_bin_links() {
    ln -sf "$ADDON_SCRIPT" "/opt/bin/$ADDON_TAG" 2>/dev/null || true
    ln -sf "$ADDON_SCRIPT" /opt/bin/ssurf 2>/dev/null || true
    ln -sf "$ADDON_SCRIPT" /opt/bin/ss 2>/dev/null || true
}

ss_cli_status() {
    show_version
    load_xrayui_config
    local pid
    pid=$(get_xray_daemon_pid 2>/dev/null || true)
    if [ -n "$pid" ]; then
        ss_cli_echo "xray: running (pid $pid)  config=$XRAY_CONFIG_FILE"
    else
        ss_cli_echo "xray: stopped  config=$XRAY_CONFIG_FILE"
    fi
    if [ -f "$SS_CACHE_CONFIGS" ]; then
        ss_cli_echo "catalog: $(jq 'length' "$SS_CACHE_CONFIGS" 2>/dev/null || echo 0) configs  last_sync=${SS_LAST_SYNC:-—}"
    fi
    if [ -f "$SS_CACHE_BALANCES" ]; then
        jq -r '"balance: \(.total_balance // 0) \(.currency // "RUB")  (\(.message // ""))"' "$SS_CACHE_BALANCES" 2>/dev/null || true
    fi
}

ss_cli_list_configs() {
    ss_api_ensure_caches
    if [ ! -f "$SS_CACHE_CONFIGS" ] || [ "$(jq 'length' "$SS_CACHE_CONFIGS" 2>/dev/null || echo 0)" = "0" ]; then
        ss_cli_echo "Catalog empty — run: ssurf sy"
        return 1
    fi
    jq -r '
      .[] |
      "\(.id)\t\(.protocol // "-")\t\(if .is_online then "online" else "-" end)\t\(.title // .name // ("ss-" + (.id|tostring)))"
    ' "$SS_CACHE_CONFIGS"
}

ss_cli_help() {
    cat <<EOF
$ADDON_TITLE $XRAYUI_VERSION — CLI

Вызов:  ssurf <к> …    или    stealthsurf <к> …    или    ss <к> …
Справка: ssurf h       Меню: ssurf m

── Коротко ────────────────────────────────────────────────
  up|on          start          dn|off         stop
  re|rs          restart        st             status
  sy             sync           ls|l           list catalog
  ic|imp|ap <id> import-config  bal            balances
  key <stlth_>   set-key        addk <k> [lbl] add-key
  rmkey <k>      remove-key
  bak            backup         d|dg           diagnostics
  upd [ver]      update         uf             update latest
  v|ver          version        fix|doctor     fixme
  un --yes       uninstall
  h|?            help           m|menu         меню

── Полные имена ───────────────────────────────────────────
  start stop restart version install uninstall update
  set-key add-key remove-key balances sync import-config
  backup diagnostics mount_ui remount_ui

Примеры:
  ssurf up
  ssurf key 'stlth_…'
  ssurf sy && ssurf ls
  ssurf ic 101 && ssurf re
  ssurf st
  ssurf m
EOF
}

ss_cli_menu() {
    cat <<EOF

$ADDON_TITLE — меню
  1) up      старт
  2) dn      стоп
  3) re      рестарт
  4) st      статус
  5) sy      sync
  6) ls      каталог
  7) bal     баланс
  8) d       diagnostics
  9) upd     update
  a|i) ap   import-config <id>
  x) un      uninstall
  h) help
  q) выход
EOF
    printf 'Выбор: '
    read -r choice || return 0
    case "$choice" in
    1 | up | on) set -- up ;;
    2 | dn | off) set -- dn ;;
    3 | re | rs) set -- re ;;
    4 | st) set -- st ;;
    5 | sy) set -- sy ;;
    6 | ls | l) set -- ls ;;
    7 | bal) set -- bal ;;
    8 | d | dg) set -- d ;;
    9 | upd)
        set -- upd
        ;;
    a | ap | A | i | ic | I)
        printf 'config id: '
        read -r cid || return 0
        set -- ap "$cid"
        ;;
    x | un)
        printf 'Точно удалить аддон? [y/N]: '
        read -r yn || return 0
        case "$yn" in
        y | Y | yes | YES) set -- un --yes ;;
        *)
            echo "Отмена"
            return 0
            ;;
        esac
        ;;
    h | help | \?) set -- h ;;
    q | Q | "")
        echo "Выход"
        return 0
        ;;
    *)
        echo "Неизвестный пункт: $choice"
        return 1
        ;;
    esac
    ss_cli_dispatch "$@"
}

ss_cli_dispatch() {
    case "$1" in
    "" | help | -h | --help | h | \?)
        ss_cli_help
        return 0
        ;;
    m | menu)
        ss_cli_menu
        return $?
        ;;
    version | v | ver)
        show_version
        return 0
        ;;
    up | on | start)
        with_restart_lock start
        return $?
        ;;
    dn | off | stop)
        with_restart_lock stop
        return $?
        ;;
    re | rs | restart)
        restart
        return $?
        ;;
    st | status)
        ss_cli_status
        return 0
        ;;
    sy | sync)
        ss_api_sync_all
        return $?
        ;;
    ls | l | list)
        ss_cli_list_configs
        return $?
        ;;
    bal | balances)
        ss_api_fetch_balances "${2:-1}"
        return $?
        ;;
    key | set-key)
        ss_api_set_primary_key "$2" "${3:-primary}"
        return $?
        ;;
    addk | add-key)
        ss_api_add_key "$2" "$3"
        return $?
        ;;
    rmkey | remove-key)
        ss_api_keys_store_remove "$2"
        return $?
        ;;
    ic | imp | ap | a | apply | import-config | import)
        if ss_api_import_config_to_xray "$2"; then
            ss_api_import_finalize
            return 0
        fi
        return 1
        ;;
    bak | backup)
        backup_configuration
        return $?
        ;;
    d | dg | diag)
        diagnostics_env
        diagnostics_xrayui
        diagnostics_iptables
        return 0
        ;;
    diagnostics)
        case "${2:-}" in
        iptables) diagnostics_iptables ;;
        env) diagnostics_env ;;
        xrayui) diagnostics_xrayui ;;
        *)
            diagnostics_env
            diagnostics_xrayui
            diagnostics_iptables
            ;;
        esac
        return 0
        ;;
    upd | update | upgrade)
        case "$2" in
        xray)
            switch_stealthsurf_version "$3" || return 1
            ;;
        *)
            update "${2:-latest}" || return 1
            ;;
        esac
        return 0
        ;;
    uf | force-update)
        update latest || return 1
        return 0
        ;;
    fix | doctor | fixme | heal | repair)
        fixme
        ss_cli_ensure_bin_links
        return $?
        ;;
    un)
        case "${2:-}" in
        --yes | -y | yes | confirm | 1)
            uninstall
            return $?
            ;;
        *)
            log_error "Short uninstall needs confirmation. Run: ssurf un --yes"
            return 1
            ;;
        esac
        ;;
    uninstall | remove | purge)
        uninstall
        return $?
        ;;
    install)
        install || return 1
        ss_cli_ensure_bin_links
        return 0
        ;;
    *)
        return 2
        ;;
    esac
}
