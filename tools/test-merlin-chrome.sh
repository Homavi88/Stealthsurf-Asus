#!/bin/sh
# Regression: left Merlin menu must survive app.js + menuTree inject on BusyBox.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail=0
ok() { echo "OK  $1"; }
bad() { echo "FAIL $1"; fail=$((fail + 1)); }

APP="$ROOT/src/ui/app.js"
ASP="$ROOT/src/ui/index.asp"
MOUNT="$ROOT/src/backend/mount.sh"

# app.js must not shadow Merlin/jQuery `$` — that aborts show_menu() before #mainMenu.
if grep -Eq '^(const|let|var)[[:space:]]+\$[[:space:]]*=' "$APP"; then
  bad "app.js binds \$"
else
  ok "app.js does not bind \$"
fi
if grep -Eq '^function[[:space:]]+\$[[:space:]]*\(' "$APP"; then
  bad "app.js function \$"
else
  ok "app.js has no function \$"
fi
grep -q 'function byId' "$APP" && ok "byId helper" || bad "byId helper"

grep -q 'id="mainMenu"' "$ASP" && ok "mainMenu placeholder" || bad "mainMenu placeholder"
grep -q 'typeof show_menu' "$ASP" && ok "show_menu call site" || bad "show_menu call site"
grep -q 'try { initial(); }' "$ASP" && ok "early initial() before app.js" || bad "early initial() before app.js"

# GNU-only `\s` in sed never matches on BusyBox routers
if grep -n 'url:\\s\*' "$MOUNT" >/dev/null 2>&1; then
  bad "mount.sh still uses GNU sed \\\\s"
else
  ok "mount.sh has no GNU sed \\\\s"
fi
grep -q 'ss_menutree_inject_tab' "$MOUNT" && ok "ss_menutree_inject_tab" || bad "ss_menutree_inject_tab"

# shellcheck disable=SC1090
sed -n '/^ss_menutree_inject_tab()/,/^}/p' "$MOUNT" >"$TMP/fn.sh"
# shellcheck disable=SC1091
. "$TMP/fn.sh"

cat >"$TMP/menuTree.js" <<'EOF'
define(function(){
return {
list: [
{
 menuName: "VPN",
 index: "menu_VPN",
 tab: [
  {url: "Advanced_VPNServer_Content.asp", tabName: "PPTP"},
  {url: "Advanced_VPNClient_Content.asp", tabName: "VPN Client"},
  {url: "NULL", tabName: "__INHERIT__"}
 ]
},
{
 menuName: "Firewall",
 index: "menu_Firewall",
 tab: [
  {url: "Advanced_BasicFirewall_Content.asp", tabName: "General"},
  {url: "NULL", tabName: "__INHERIT__"}
 ]
}
]
};
});
EOF

ss_menutree_inject_tab "user2.asp" "$TMP/menuTree.js" "$TMP/out.js" || bad "inject returns 0"
grep -q '{ url: "user2.asp", tabName: "StealthSurf" }' "$TMP/out.js" && ok "tab inserted" || bad "tab inserted"
# Only in VPN section: StealthSurf line must appear before menu_Firewall
awk '
  /tabName: "StealthSurf"/ { s=NR }
  /index: "menu_Firewall"/ { f=NR }
  END { if (s && f && s < f) exit 0; else exit 1 }
' "$TMP/out.js" && ok "inserted under VPN" || bad "inserted under VPN"

# Idempotent: running on already-injected tree keeps a single tab
ss_menutree_inject_tab "user2.asp" "$TMP/out.js" "$TMP/out2.js" || bad "re-inject"
cnt=$(grep -c 'tabName: "StealthSurf"' "$TMP/out2.js" || true)
[ "$cnt" = "1" ] && ok "single tab after re-inject" || bad "single tab after re-inject (got $cnt)"

# Spaced variant used by some addons / firmware copies
cat >"$TMP/spaced.js" <<'EOF'
{
	index: "menu_VPN",
	tab: [
		{ url: "Advanced_VPNClient_Content.asp", tabName: "VPN" },
		{ url: "NULL", tabName: "__INHERIT__" }
	]
},
{
	index: "menu_Firewall",
	tab: [
		{ url: "NULL", tabName: "__INHERIT__" }
	]
}
EOF
ss_menutree_inject_tab "user1.asp" "$TMP/spaced.js" "$TMP/spaced.out.js" || bad "spaced inject"
grep -q 'user1.asp' "$TMP/spaced.out.js" && ok "spaced inherit matched" || bad "spaced inherit matched"

if [ "$fail" -ne 0 ]; then
  echo "FAILED $fail"
  exit 1
fi
echo "All merlin-chrome checks passed"
exit 0
