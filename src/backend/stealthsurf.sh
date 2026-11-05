#!/bin/sh

import ./_globals.sh
import ./_helper.sh
import ./api_client.sh
import ./link_parse.sh
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
set-key)
  SS_API_KEY="$2"
  [ -n "$SS_API_KEY" ] || {
    echo "usage: $0 set-key <stlth_...>"
    exit 1
  }
  ss_save_conf
  ss_api_verify_key || exit 1
  ;;
verify)
  ss_api_verify_key || exit 1
  ;;
sync)
  ss_api_sync_configs || exit 1
  ss_api_sync_locations || true
  ;;
list)
  [ -f "$SS_CACHE_CONFIGS" ] || ss_api_sync_configs >/dev/null || exit 1
  jq -r '.[] | select(. != null) | "\(.id)\t\(.protocol)\t\(.title // "-")\t\(.location_id)\texp=\(.expires_at)"' "$SS_CACHE_CONFIGS"
  ;;
apply)
  ss_apply_config_id "$2" || exit 1
  ;;
update-settings)
  ss_api_update_settings "$2" "$3" || exit 1
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
service_event)
  ss_service_event "$2" "$3" || exit 1
  ;;
*)
  cat <<EOF
Usage: $0 {install|uninstall|version|set-key|verify|sync|list|apply|update-settings|start|stop|restart|status|mount_ui|unmount_ui}
EOF
  exit 1
  ;;
esac

exit 0
