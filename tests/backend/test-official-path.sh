#!/bin/sh
# Guard: our package must never claim /jffs/addons/stealthsurf (official VPN).
set -e
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
TGZ="$ROOT/packaged/asuswrt-merlin-surfgate.tar.gz"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass() { echo "OK  $*"; }
fail() { echo "FAIL  $*" >&2; exit 1; }

test -s "$TGZ" || fail "missing $TGZ (run pnpm pack)"

tar -tzf "$TGZ" | grep -q '^ssurf/' || fail "archive root is not ssurf/"
tar -tzf "$TGZ" | grep -q '^stealthsurf/' && fail "archive still contains stealthsurf/ root" || pass "no stealthsurf/ root in archive"

tar -xzf "$TGZ" -C "$TMP"
BIN="$TMP/ssurf/stealthsurf"
test -f "$BIN" || fail "ssurf/stealthsurf missing"

grep -q 'ADDON_PKG_NAME="ssurf"' "$BIN" || fail "ADDON_PKG_NAME not ssurf"
grep -q 'OFFICIAL_SS_DAEMON=' "$BIN" || fail "OFFICIAL_SS_DAEMON missing"
grep -q '/jffs/addons/ssurf' "$BIN" || grep -q 'ADDON_JFFS_ADN_DIR="/jffs/addons/\$ADDON_PKG_NAME"' "$BIN" ||
  fail "JFFS dir not bound to ssurf"
# Uninstall/update must not blindly rm -rf /jffs/addons/stealthsurf
grep -E 'rm -rf "/jffs/addons/stealthsurf"|rm -rf \$OFFICIAL_SS_JFFS_DIR|rm -rf "\$OFFICIAL_SS_JFFS_DIR"' "$BIN" &&
  fail "script removes official JFFS tree wholesale" || pass "does not wipe official tree"

grep -q 'XRAYUI_VERSION="1.4.2"' "$BIN" || fail "version not 1.4.2"
grep -q 'ADDON_TITLE="SurfGate"' "$BIN" || fail "ADDON_TITLE not SurfGate"
pass "official path coexistence guards"
echo "ALL PASS"
