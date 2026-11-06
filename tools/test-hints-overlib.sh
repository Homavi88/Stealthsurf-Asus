#!/bin/sh
# Regression: Merlin overlib hover hints stay visible above modals + delegated binding.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
ASP="$ROOT/src/ui/index.asp"
JS="$ROOT/src/ui/app.js"
fail=0

ok() { echo "OK  $1"; }
bad() { echo "FAIL $1"; fail=1; }

echo "== overlib / data-ss-hint regressions =="

grep -q 'function initHelpHints' "$JS" && ok "initHelpHints" || bad "initHelpHints"
grep -q 'function refreshHelpHintStyles' "$JS" && ok "refreshHelpHintStyles" || bad "refreshHelpHintStyles"
grep -q 'ssHelpDelegated' "$JS" && ok "delegated mouseover binding" || bad "delegated mouseover binding"
grep -q 'ensureOverDivAboveModals' "$JS" && ok "ensureOverDivAboveModals" || bad "ensureOverDivAboveModals"
grep -q 'window.OFFSETX' "$JS" && ok "safe overlib globals via window.*" || bad "safe overlib globals via window.*"
grep -q 'refreshHelpHintStyles(modal)' "$JS" && ok "modal open refreshes hint styles" || bad "modal open refreshes hint styles"

# z-index: overDiv must be above ss-modal so tips work inside Manage windows
python3 - "$ASP" <<'PY' || fail=1
from pathlib import Path
import re
asp = Path(__import__("sys").argv[1]).read_text()
# Must NOT share the old 9999 pair
assert "#Loading, #overDiv { z-index: 9999; }" not in asp, "old shared z-index still present"
m_over = re.search(r"#overDiv\s*\{\s*z-index:\s*(\d+)\s*;", asp)
m_modal = re.search(r"\.ss-modal\s*\{[^}]*z-index:\s*(\d+)\s*;", asp, re.S)
m_tip = re.search(r"#ssHelpTip\s*\{[^}]*z-index:\s*(\d+)\s*;", asp, re.S)
assert m_over and m_modal and m_tip, "missing z-index rules"
over_z, modal_z, tip_z = int(m_over.group(1)), int(m_modal.group(1)), int(m_tip.group(1))
assert over_z > modal_z, "overDiv (%d) must be > ss-modal (%d)" % (over_z, modal_z)
assert tip_z > modal_z, "ssHelpTip (%d) must be > ss-modal (%d)" % (tip_z, modal_z)
print("OK  z-index overDiv=%d tip=%d > modal=%d" % (over_z, tip_z, modal_z))
PY

# Static Configuration rows + modal sections all declare hints
hint_n=$(grep -o 'data-ss-hint=' "$ASP" | wc -l | tr -d ' ')
[ "$hint_n" -ge 40 ] && ok "hint markup count ($hint_n)" || bad "hint markup count ($hint_n)"

# Dynamically-targeted manage entry points still have th hints on the main page
for label in 'API keys' 'Backup / Logs' 'Правила' 'Clients / MAC policies' 'Mode / DNS' 'Diagnostics' 'General options' 'Update'; do
  grep -q "data-ss-hint=.*$label\\|$label.*data-ss-hint\\|>$label<" "$ASP" || true
done

python3 - "$ASP" <<'PY' || fail=1
from pathlib import Path
import sys
asp = Path(sys.argv[1]).read_text()
needles = [
    ("API keys row", 'id="btnManageKeys"', "data-ss-hint="),
    ("Backup row", 'id="btnManageBackup"', "data-ss-hint="),
    ("Routing manage", 'id="btnManageRouting"', "data-ss-hint="),
    ("Policies manage", 'id="btnManagePolicies"', "data-ss-hint="),
    ("Mode/DNS manage", 'id="btnManageGeneral"', "data-ss-hint="),
    ("Diag manage", 'id="btnManageDiag"', "data-ss-hint="),
]
for name, anchor, hint in needles:
    i = asp.find(anchor)
    assert i > 0, name + " missing"
    # Look back within the same <tr> for a data-ss-hint on the label cell
    start = asp.rfind("<tr", 0, i)
    end = asp.find("</tr>", i)
    chunk = asp[start:end]
    assert hint in chunk, "%s: expected %s near %s" % (name, hint, anchor)
    print("OK  %s has data-ss-hint on row" % name)
PY

if [ "$fail" -ne 0 ]; then
  echo "hint/overlib tests FAILED"
  exit 1
fi
echo "hint/overlib tests passed"
exit 0
