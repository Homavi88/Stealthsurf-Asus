#!/bin/sh

import ./_globals.sh
import ./_helper.sh
import ./api_client.sh
import ./link_parse.sh
import ./routing.sh
import ./policies.sh
import ./logging.sh
import ./firewall.sh
import ./dnsmasq.sh
import ./protocols.sh
import ./xray_bin.sh
import ./diag.sh
import ./backup.sh
import ./settings.sh
import ./telegram.sh
import ./version.sh
import ./startup.sh
import ./control.sh
import ./mount.sh
import ./hooks.sh
import ./install.sh
import ./service_event.sh

ss_cli_help() {
  cat <<EOF
$ADDON_TITLE $ADDON_VERSION — CLI

Вызов:  ssurf <к> …    или    stealthsurf <к> …
Справка: ssurf h       Меню: ssurf m

── Коротко (запоминайте эти) ───────────────────────────────
  up|on          start          dn|off         stop
  re|rs          restart        st             status
  sy             sync           ls|l           list
  ap|a <id>      apply          en <id>        enable
  dis <id>       disable        def <tag>      set-default
  key <stlth_>   set-key        bal            balances
  mode <m>       set-mode       dns <m>        set-dns-mode
  rb             rebuild
  v|ver          version        cu|chk         check-update
  upd [ -f ]     update         uf             force-update
  lv             list-versions  iv <tag>       install-version / rollback
  d|dg           diag           p|proto        protocols
  log [src] [n]  logs           bak [note]     backup
  baks           backups        cl             clients
  dev            devices        conn [url]     connectivity
  xray           install-xray   geo            geodata
  cfg            settings       setcfg '<json>' set-settings
  tg             telegram       tg-start/stop  бот on/off
  tg-test        telegram-test  проверка API токена
  un --yes       uninstall      doctor         восстановить UI/CLI
  h|?            help           m|menu         интерактивное меню

── Полные имена (как раньше) ───────────────────────────────
  start stop restart status install uninstall version
  check-update update force-update list-versions install-version
  set-key add-key remove-key verify balances sync list apply enable disable
  set-default update-settings set-routing preset set-policies clients
  set-mode set-dns-mode rebuild diag test-config connectivity
  protocols logs devices backup backups restore
  install-xray geodata settings set-settings
  telegram telegram-start telegram-stop telegram-tick telegram-daemon
  telegram-test [token]

Примеры:
  ssurf up
  ssurf sy && ssurf ls
  ssurf ap 101 && ssurf mode redirect && ssurf up
  ssurf st
  ssurf cu && ssurf upd
  ssurf lv && ssurf iv v1.0.16   # список релизов + откат на выбранную
  ssurf m
EOF
}

ss_cli_menu() {
  # Interactive short menu — no need to remember every alias
  cat <<EOF

$ADDON_TITLE — меню
  1) up      старт VPN
  2) dn      стоп VPN
  3) re      рестарт
  4) st      статус
  5) sy      sync с сайта
  6) ls      список конфигов
  7) d       diag
  8) p       protocols
  9) cu      check-update
  a) ap      apply <id>
  e) en      enable <id>
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
  7 | d | dg) set -- d ;;
  8 | p | proto) set -- p ;;
  9 | cu | chk) set -- cu ;;
  a | ap | A)
    printf 'config id: '
    read -r cid || return 0
    set -- ap "$cid"
    ;;
  e | en | E)
    printf 'config id: '
    read -r cid || return 0
    set -- en "$cid"
    ;;
  x | un)
    printf 'Точно удалить аддон? [y/N]: '
    read -r yn || return 0
    case "$yn" in
    y | Y | yes | YES) set -- uninstall --yes ;;
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
  # Re-enter dispatcher with chosen short command
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
    echo "$ADDON_TITLE $ADDON_VERSION"
    ss_version_local >/dev/null 2>&1 || true
    if [ -f "$SS_VERSION_FILE" ]; then
      jq -r '"installed=\(.installed) latest=\(.latest // "-") update=\(.update_available)"' "$SS_VERSION_FILE" 2>/dev/null || true
    fi
    ;;
  check-update | version-check | checkupdate | cu | chk)
    ss_version_check || return 1
    ;;
  update | upgrade | upd)
    force=0
    case "${2:-}" in
    --force | -f | force | 1) force=1 ;;
    esac
    if [ "$force" = "1" ]; then
      # Silence JSON on stdout; keep stderr for progress/status
      ss_version_check >/dev/null || true
      ss_update_self || return 1
    else
      ss_version_update_if_available 0
      rc=$?
      [ "$rc" = "0" ] || [ "$rc" = "2" ] || return 1
    fi
    ;;
  force-update | update-force | uf)
    ss_version_check >/dev/null || true
    ss_update_self || return 1
    ;;
  update-if-newer)
    ss_version_update_if_available "${2:-0}"
    rc=$?
    [ "$rc" = "0" ] || [ "$rc" = "2" ] || return 1
    ;;
  list-versions | versions | lv)
    ss_version_list || return 1
    if [ -f "$SS_VERSIONS_FILE" ]; then
      jq -r '
        "installed=\(.installed)",
        (.releases[]? | "  \(.tag)\t\(.direction)\t\(.changelog.headline // "")")
      ' "$SS_VERSIONS_FILE" 2>/dev/null || cat "$SS_VERSIONS_FILE"
    fi
    ;;
  install-version | switch-version | rollback | roll | iv)
    tag="${2:-}"
    force_tag=0
    case "${3:-}" in
    --force | -f | force | 1) force_tag=1 ;;
    esac
    case "${2:-}" in
    --force | -f | force | 1)
      force_tag=1
      tag="${3:-}"
      ;;
    esac
    [ -n "$tag" ] || {
      echo "usage: ssurf iv <tag>   e.g. ssurf iv v1.0.16"
      return 1
    }
    SS_FORCE_TAG="$force_tag"
    export SS_FORCE_TAG
    ss_version_install_tag "$tag"
    rc=$?
    unset SS_FORCE_TAG
    [ "$rc" = "0" ] || [ "$rc" = "2" ] || return 1
    ;;
  install)
    ss_install || return 1
    ;;
  uninstall | remove | purge | un)
    # Require explicit confirmation — former alias `rm` was too easy to run by mistake
    # and wiped the whole addon (UI + CLI). Usage: ssurf un --yes
    case "${2:-}" in
    --yes | -y | yes | confirm | 1) ss_uninstall ;;
    *)
      ss_error "uninstall refuses without confirmation. Run: ssurf un --yes"
      ss_info "If the tab/CLI vanished after a glitch, try first: ssurf doctor"
      return 1
      ;;
    esac
    ;;
  doctor | heal | fix | repair)
    ss_doctor || return 1
    ;;
  mount_ui)
    ss_mount_ui || return 1
    ;;
  unmount_ui)
    ss_unmount_ui
    ;;
  autostart)
    ss_autostart || return 1
    ;;
  startup)
    ss_startup "$2" || return 1
    ;;
  wan-up)
    ss_wan_up_hook || return 1
    ;;
  firewall-restore)
    ss_firewall_restore_hook || return 1
    ;;
  dnsmasq-configure)
    ss_dnsmasq_configure_hook "$2" || return 1
    ;;
  set-key | key | sk)
    SS_API_KEY="$2"
    [ -n "$SS_API_KEY" ] || {
      echo "usage: ssurf key <stlth_...>"
      return 1
    }
    ss_save_conf
    ss_api_verify_key || return 1
    ;;
  add-key)
    ss_api_add_key "$2" "$3" || return 1
    ;;
  remove-key)
    ss_api_keys_store_remove "$2" || return 1
    ;;
  verify)
    ss_api_verify_key || return 1
    ;;
  balances | balance | bal)
    # Force refresh account balance(s) for all configured API keys
    ss_api_fetch_balances 1 || return 1
    ;;
  sync | sy)
    ss_sync_from_provider || return 1
    ;;
  autosync)
    ss_sync_from_provider >/dev/null 2>&1 || true
    ;;
  list | ls | l)
    [ -f "$SS_CACHE_CONFIGS" ] || ss_api_sync_configs >/dev/null || return 1
    jq -r '.[] | select(. != null) | "\(.id)\t\(.protocol)\t\(.title // "-")\t\(.location_id)\texp=\(.expires_at)\tonline=\(.is_online)"' "$SS_CACHE_CONFIGS"
    ;;
  apply | ap | a)
    ss_apply_config_id "$2" "${3:-1}" || return 1
    ;;
  enable | en)
    ss_enable_outbound "$2" && ss_rebuild_and_restart || return 1
    ;;
  disable | dis)
    ss_disable_outbound "$2" && ss_rebuild_and_restart || return 1
    ;;
  set-default | def)
    ss_set_default_outbound "$2" && ss_rebuild_and_restart || return 1
    ;;
  set-outbounds)
    ss_set_enabled_outbounds "$2" "$3" && ss_rebuild_and_restart || return 1
    ;;
  set-routing)
    ss_routing_set_rules "$2" "$3" "$4" && ss_rebuild_and_restart || return 1
    ;;
  preset)
    ss_routing_apply_preset "$2" "$3" "$4" && ss_rebuild_and_restart || return 1
    ;;
  set-policies)
    ss_policies_set "$2" || return 1
    if ss_xray_running; then
      ss_cleanup_firewall
      ss_configure_firewall
    fi
    ;;
  clients | cl)
    ss_clientlist_json
    ;;
  set-mode | mode | sm)
    ss_set_mode "$2" || return 1
    ;;
  set-dns-mode | dns | sdns)
    ss_set_dns_mode "$2" || return 1
    ;;
  update-settings | us)
    ss_api_update_settings "$2" "$3" || return 1
    ;;
  rebuild | rb)
    ss_rebuild_and_restart || return 1
    ;;
  start | up | on)
    ss_start || return 1
    ;;
  stop | dn | off)
    ss_stop || return 1
    ;;
  restart | re | rs)
    ss_restart || return 1
    ;;
  status | st)
    ss_status
    ;;
  watchdog)
    ss_watchdog_tick || return 1
    ;;
  diag | d | dg)
    ss_diag_dump
    ;;
  test-config | tc)
    ss_test_xray_config || return 1
    ;;
  connectivity | conn)
    ss_connectivity_check "$2" "${3:-socks}"
    ;;
  logs | log)
    ss_tail_logs "${2:-activity}" "${3:-100}"
    ;;
  clear-logs)
    ss_logs_clear "${2:-all}" || return 1
    ;;
  devices | dev)
    ss_log_devices_snapshot
    ss_tail_logs devices 100
    ;;
  backup | bak)
    ss_backup "${2:-manual}" || return 1
    ;;
  backups | baks)
    ss_backup_list
    ;;
  restore)
    ss_restore "$2" || return 1
    ;;
  install-xray | xray)
    ss_ensure_xray || return 1
    ;;
  geodata | geo)
    ss_geodata_update || return 1
    ;;
  settings | cfg | get-settings)
    ss_settings_publish 2>/dev/null || true
    ss_settings_json
    ;;
  set-settings | setcfg)
    ss_settings_apply "${2:-{}}" || return 1
    ;;
  telegram | tg)
    ss_settings_json | jq '.telegram // {}'
    if ss_telegram_running; then
      echo "daemon: running (pid $(cat "$SS_TG_PIDFILE" 2>/dev/null))"
    else
      echo "daemon: stopped"
    fi
    ;;
  telegram-start | tg-start)
    SS_TG_ENABLED=1
    ss_telegram_start_daemon || return 1
    ;;
  telegram-stop | tg-stop)
    ss_telegram_stop_daemon
    ss_ok "Telegram bot stopped"
    ;;
  telegram-tick | tg-tick)
    ss_telegram_tick || return 1
    ;;
  telegram-test | tg-test | test-telegram)
    # ssurf tg-test [token] — prints JSON from getMe probe
    ss_telegram_test_connection "${2:-}" "${3:-}" || return 1
    ;;
  telegram-daemon | tg-daemon)
    ss_telegram_daemon_loop
    ;;
  protocols | p | proto)
    ss_protocol_status_matrix
    ;;
  service_event)
    ss_service_event "$2" "$3" || return 1
    ;;
  *)
    echo "Unknown command: $1" >&2
    echo "Run: ssurf h   or   ssurf m" >&2
    return 1
    ;;
  esac
  return 0
}

ss_cli_dispatch "$@" || exit $?
exit 0
