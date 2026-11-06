#!/bin/sh
# Regression: Configuration hosts keys/backup; Outbounds is XrayUI-style list; Routing opens modal.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
ASP="$ROOT/src/ui/index.asp"
JS="$ROOT/src/ui/app.js"
fail=0

check() {
  label=$1
  file=$2
  pattern=$3
  if grep -Eq -- "$pattern" "$file"; then
    echo "OK  $label"
  else
    echo "FAIL $label"
    fail=1
  fi
}

check_not() {
  label=$1
  file=$2
  pattern=$3
  if grep -Eq -- "$pattern" "$file"; then
    echo "FAIL $label (unexpected)"
    fail=1
  else
    echo "OK  $label"
  fi
}

echo "== UI Configuration / Outbounds layout =="

check "Configuration block" "$ASP" 'id="sec-config"'
check "API keys inside Configuration area" "$ASP" 'id="btnManageKeys"'
check "Backup inside Configuration area" "$ASP" 'id="btnManageBackup"'
check "Outbounds section on main page" "$ASP" 'id="sec-outbounds"'
check "outbound list body" "$ASP" 'id="outboundListBody"'
check "Routing section" "$ASP" 'id="sec-routing"'
check "Routing manage" "$ASP" 'id="btnManageRouting"'
check "keys modal" "$ASP" 'id="keysModal"'
check "catalog/edit modal" "$ASP" 'id="catalogModal"'
check "routing modal" "$ASP" 'id="routingModal"'
check "backup modal" "$ASP" 'id="backupModal"'

# Keys/Backup rows should appear before Advanced menu, inside sec-config
python3 - <<'PY' || fail=1
from pathlib import Path
asp = Path("src/ui/index.asp").read_text()
i_cfg = asp.find('id="sec-config"')
i_keys = asp.find('id="btnManageKeys"')
i_backup = asp.find('id="btnManageBackup"')
i_out = asp.find('id="sec-outbounds"')
i_route = asp.find('id="sec-routing"')
i_menu = asp.find('id="sec-menu"')
i_keys_modal = asp.find('id="keysModal"')
assert i_cfg > 0
assert i_cfg < i_keys < i_backup < i_out, "keys/backup must be in Configuration before Outbounds"
assert i_out < i_route < i_menu, "Outbounds then Routing then Advanced"
assert i_keys_modal > i_menu, "modals after main sections"
# No separate Управление block title
assert ">Управление<" not in asp, "old Управление section should be gone"
print("OK  Configuration → Outbounds → Routing → Advanced order")
PY

check "openConfigEditModal" "$JS" 'function openConfigEditModal'
check "ss-proxy-row render" "$JS" 'ss-proxy-row'
check "openSsModal helper" "$JS" 'function openSsModal'
check "modal th shrink-wrap" "$ASP" 'ss-modal-card \.FormTable th'
check_not "no catalog manage button" "$ASP" 'id="btnManageCatalog"'

if [ "$fail" -ne 0 ]; then
  echo "UI layout tests FAILED"
  exit 1
fi
echo "UI layout tests passed"
exit 0
