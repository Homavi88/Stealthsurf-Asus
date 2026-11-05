#!/bin/sh

import ./_globals.sh
import ./_helper.sh
import ./api_client.sh
import ./link_parse.sh
import ./routing.sh
import ./policies.sh
import ./firewall.sh
import ./dnsmasq.sh
import ./protocols.sh
import ./xray_bin.sh
import ./diag.sh
import ./backup.sh
import ./control.sh
import ./mount.sh
import ./hooks.sh
import ./install.sh
import ./service_event.sh

case "$1" in
version)
  echo "$ADDON_TITLE $ADDON_VERSION"
  ;;
install)
  ss_install || exit 1
  ;;
uninstall)
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
  # After sync, rebuild if running so PATCH'd URLs take effect
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
  # set-outbounds '[101,205]' 'ss-205'
  ss_set_enabled_outbounds "$2" "$3" && ss_rebuild_and_restart || exit 1
  ;;
set-routing)
  # set-routing '<rules-json>' [default] [preset]
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
  ss_tail_logs "${2:-addon}" "${3:-100}"
  ;;
backup)
  ss_backup
  ;;
restore)
  ss_restore "$2" || exit 1
  ;;
update)
  ss_update_self || exit 1
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
  cat <<EOF
Usage: $0 <command>

Lifecycle:
  install | uninstall | update | version
  start | stop | restart | status | watchdog | autostart
  mount_ui | unmount_ui | firewall-restore

API / catalog:
  set-key <stlth_...> | add-key <key> [label] | remove-key <key> | verify
  sync | autosync | list
  apply <config_id> [sole=1]
  enable <id> | disable <id> | set-default <ss-id|direct|block>
  set-outbounds '<json-array>' [default]
  update-settings <id> '<json>'

Routing / policies / mode:
  set-routing '<rules-json>' [default] [preset]
  preset <all-vpn|ru-direct|streaming-split|block-ads> <default_id> [alt_id]
  set-policies '<json>' | clients
  set-mode <proxy|redirect|tproxy>
  set-dns-mode <OFF|BYPASS|REDIRECT>
  rebuild

Dataplane helpers:
  install-xray | geodata | protocols
  diag | test-config | connectivity [url] [socks|direct]
  logs [addon|access|error] [lines]
  backup | restore <archive.tar.gz>
EOF
  exit 1
  ;;
esac

exit 0
