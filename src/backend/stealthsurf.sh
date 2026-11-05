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
import ./version.sh
import ./startup.sh
import ./control.sh
import ./mount.sh
import ./hooks.sh
import ./install.sh
import ./service_event.sh

ss_cli_help() {
  cat <<EOF
$ADDON_TITLE $ADDON_VERSION — управление аддоном на роутере

Использование: $0 <команда> [аргументы]
       или:    stealthsurf <команда>   (symlink /opt/bin/stealthsurf)

── Жизненный цикл ──────────────────────────────────────────
  start                 Запустить VPN (Xray + firewall)
  stop                  Остановить VPN и снять правила
  restart               Рестарт без полной остановки side-runtime
  status                JSON-статус (running, mode, ports…)
  install               Установить/переустановить хуки, UI, deps
  uninstall | remove | purge
                        ПОЛНОЕ удаление с роутера (хуки, cron, UI, данные)
  version               Показать установленную версию
  check-update | version-check
                        Проверить GitHub Releases (пишет version.json)
  update | upgrade      Проверить и установить новую версию, если есть
  update --force | force-update
                        Принудительно скачать и поставить latest с GitHub

── API / каталог ───────────────────────────────────────────
  set-key <stlth_…>     Сохранить основной API-ключ
  add-key <key> [label] Добавить ключ
  remove-key <key>      Удалить ключ
  verify                Проверить ключ
  sync                  Синхронизировать configs/locations/subs
  list                  Список конфигов
  apply <id> [sole=1]   Применить конфиг как outbound
  enable <id> | disable <id> | set-default <ss-id|direct|block>
  update-settings <id> '<json>'

── Routing / политики / режим ──────────────────────────────
  set-routing '<rules-json>' [default] [preset]
  preset <all-vpn|ru-direct|streaming-split|block-ads> <default_id> [alt_id]
  set-policies '<json>' | clients
  set-mode <proxy|redirect|tproxy>
  set-dns-mode <OFF|BYPASS|REDIRECT>
  rebuild

── Диагностика ─────────────────────────────────────────────
  diag | test-config | connectivity [url] [socks|direct]
  protocols
  logs [activity|addon|errors|devices|…] [lines]
  devices | backup [note] | backups | restore <file>
  install-xray | geodata

Примеры:
  stealthsurf start
  stealthsurf stop
  stealthsurf restart
  stealthsurf check-update
  stealthsurf update
  stealthsurf update --force
  stealthsurf uninstall
EOF
}

case "$1" in
"" | help | -h | --help)
  ss_cli_help
  exit 0
  ;;
version)
  echo "$ADDON_TITLE $ADDON_VERSION"
  ss_version_local >/dev/null 2>&1 || true
  if [ -f "$SS_VERSION_FILE" ]; then
    jq -r '"installed=\(.installed) latest=\(.latest // "-") update=\(.update_available)"' "$SS_VERSION_FILE" 2>/dev/null || true
  fi
  ;;
check-update | version-check | checkupdate)
  ss_version_check || exit 1
  ;;
update | upgrade)
  # update [--force|force|1]
  force=0
  case "${2:-}" in
  --force | -f | force | 1) force=1 ;;
  esac
  if [ "$force" = "1" ]; then
    ss_version_check >/dev/null 2>&1 || true
    ss_update_self || exit 1
  else
    ss_version_update_if_available 0 || exit 1
  fi
  ;;
force-update | update-force)
  ss_version_check >/dev/null 2>&1 || true
  ss_update_self || exit 1
  ;;
update-if-newer)
  ss_version_update_if_available "${2:-0}" || exit 1
  ;;
install)
  ss_install || exit 1
  ;;
uninstall | remove | purge)
  ss_uninstall
  ;;
mount_ui)
  ss_mount_ui || exit 1
  ;;
unmount_ui)
  ss_unmount_ui
  ;;
autostart)
  ss_autostart || exit 1
  ;;
startup)
  ss_startup "$2" || exit 1
  ;;
wan-up)
  ss_wan_up_hook || exit 1
  ;;
firewall-restore)
  ss_firewall_restore_hook || exit 1
  ;;
dnsmasq-configure)
  ss_dnsmasq_configure_hook "$2" || exit 1
  ;;
set-key)
  SS_API_KEY="$2"
  [ -n "$SS_API_KEY" ] || {
    echo "usage: $0 set-key <stlth_...>"
    exit 1
  }
  ss_save_conf
  ss_api_verify_key || exit 1
  ;;
add-key)
  ss_api_add_key "$2" "$3" || exit 1
  ;;
remove-key)
  ss_api_keys_store_remove "$2" || exit 1
  ;;
verify)
  ss_api_verify_key || exit 1
  ;;
sync)
  ss_api_sync_all || exit 1
  ;;
autosync)
  ss_api_sync_all >/dev/null 2>&1 || true
  if ss_xray_running; then
    ss_rebuild_and_restart >/dev/null 2>&1 || true
  fi
  ;;
list)
  [ -f "$SS_CACHE_CONFIGS" ] || ss_api_sync_configs >/dev/null || exit 1
  jq -r '.[] | select(. != null) | "\(.id)\t\(.protocol)\t\(.title // "-")\t\(.location_id)\texp=\(.expires_at)\tonline=\(.is_online)"' "$SS_CACHE_CONFIGS"
  ;;
apply)
  ss_apply_config_id "$2" "${3:-1}" || exit 1
  ;;
enable)
  ss_enable_outbound "$2" && ss_rebuild_and_restart || exit 1
  ;;
disable)
  ss_disable_outbound "$2" && ss_rebuild_and_restart || exit 1
  ;;
set-default)
  ss_set_default_outbound "$2" && ss_rebuild_and_restart || exit 1
  ;;
set-outbounds)
  ss_set_enabled_outbounds "$2" "$3" && ss_rebuild_and_restart || exit 1
  ;;
set-routing)
  ss_routing_set_rules "$2" "$3" "$4" && ss_rebuild_and_restart || exit 1
  ;;
preset)
  ss_routing_apply_preset "$2" "$3" "$4" && ss_rebuild_and_restart || exit 1
  ;;
set-policies)
  ss_policies_set "$2" || exit 1
  if ss_xray_running; then
    ss_cleanup_firewall
    ss_configure_firewall
  fi
  ;;
clients)
  ss_clientlist_json
  ;;
set-mode)
  ss_set_mode "$2" || exit 1
  ;;
set-dns-mode)
  ss_set_dns_mode "$2" || exit 1
  ;;
update-settings)
  ss_api_update_settings "$2" "$3" || exit 1
  ;;
rebuild)
  ss_rebuild_and_restart || exit 1
  ;;
start)
  ss_start || exit 1
  ;;
stop)
  ss_stop || exit 1
  ;;
restart)
  ss_restart || exit 1
  ;;
status)
  ss_status
  ;;
watchdog)
  ss_watchdog_tick || exit 1
  ;;
diag)
  ss_diag_dump
  ;;
test-config)
  ss_test_xray_config || exit 1
  ;;
connectivity)
  ss_connectivity_check "$2" "${3:-socks}"
  ;;
logs)
  ss_tail_logs "${2:-activity}" "${3:-100}"
  ;;
clear-logs)
  ss_logs_clear "${2:-all}" || exit 1
  ;;
devices)
  ss_log_devices_snapshot
  ss_tail_logs devices 100
  ;;
backup)
  ss_backup "${2:-manual}" || exit 1
  ;;
backups)
  ss_backup_list
  ;;
restore)
  ss_restore "$2" || exit 1
  ;;
install-xray)
  ss_ensure_xray || exit 1
  ;;
geodata)
  ss_geodata_update || exit 1
  ;;
protocols)
  ss_protocol_status_matrix
  ;;
service_event)
  ss_service_event "$2" "$3" || exit 1
  ;;
*)
  echo "Unknown command: $1" >&2
  echo "Run: $0 help" >&2
  exit 1
  ;;
esac

exit 0
