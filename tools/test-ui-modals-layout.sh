#!/bin/sh
# Regression: section blocks live in modals (XrayUI-style), not a long stacked page.
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
    echo "FAIL $label (unexpected match)"
    fail=1
  else
    echo "OK  $label"
  fi
}

echo "== UI modal layout =="

# Compact manage menu on main page
check "section menu present" "$ASP" 'id="sec-menu"'
check "manage keys button" "$ASP" 'id="btnManageKeys"'
check "manage catalog button" "$ASP" 'id="btnManageCatalog"'
check "manage routing button" "$ASP" 'id="btnManageRouting"'

# Heavy panels inside modals
for mid in keysModal catalogModal routingModal policiesModal generalModal backupModal diagModal; do
  check "modal $mid" "$ASP" "id=\"$mid\""
done

# Config table / editors are under catalogModal (not free-floating after Configuration)
# Approximate: catalogModal opens before configTable
python3 - <<'PY' || fail=1
from pathlib import Path
asp = Path("src/ui/index.asp").read_text()
i_menu = asp.find('id="sec-menu"')
i_cat = asp.find('id="catalogModal"')
i_cfg = asp.find('id="configTable"')
i_keys = asp.find('id="keysModal"')
i_api = asp.find('id="apiKey"')
assert i_menu > 0 and i_cat > i_menu, "catalog modal should follow section menu"
assert i_cfg > i_cat, "configTable must live inside/after catalogModal"
assert i_api > i_keys, "apiKey field must live inside/after keysModal"
print("OK  panels nested after their modals")
PY

# JS wires manage → openSsModal
check "openSsModal helper" "$JS" 'function openSsModal'
check "SS_SECTION_MODALS map" "$JS" 'SS_SECTION_MODALS'
check "manageMap wiring" "$JS" 'btnManageCatalog'
check "summaries helper" "$JS" 'function updateSectionSummaries'
check "short outbound btn" "$JS" 'btn.value = enabled \? "Выкл" : "Вкл"'

# Mobile helpers
check "table scroll css" "$ASP" 'ss-table-scroll'
check "wide modal css" "$ASP" 'ss-wide-card'
check "hide-sm columns" "$ASP" 'ss-col-hide-sm'

if [ "$fail" -ne 0 ]; then
  echo "UI modal layout tests FAILED"
  exit 1
fi
echo "UI modal layout tests passed"
exit 0
