#!/bin/sh
# update_community_geodata skip_if_present must not download when .dat already exist
set -e
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export ADDON_TMP_DIR="$TMP/tmp"
export GEODATA_MIN_BYTES=100
mkdir -p "$ADDON_TMP_DIR" "$TMP/sbin"

# Fake xray binary so dirname/which resolve
cat >"$TMP/sbin/xray" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$TMP/sbin/xray"
export PATH="$TMP/sbin:$PATH"

# Present large-enough community dats
dd if=/dev/zero of="$TMP/sbin/geosite.dat" bs=1 count=200 2>/dev/null
dd if=/dev/zero of="$TMP/sbin/geoip.dat" bs=1 count=200 2>/dev/null

FETCHED=0
github_download() {
  FETCHED=$((FETCHED + 1))
  return 1
}
geodata_fetch_one() {
  FETCHED=$((FETCHED + 1))
  return 1
}
log_info() { :; }
log_ok() { :; }
log_warn() { :; }
log_error() { echo "ERR: $*" >&2; }
log_debug() { :; }
load_xrayui_config() { :; }
update_loading_progress() { :; }
install_ui_status() { :; }
install_ui_humansize() { echo "$1"; }
geodata_recompile_all() { echo "recompile" >>"$TMP/recompile.txt"; }

# shellcheck disable=SC1091
. "$ROOT/src/backend/geodata.sh"

update_community_geodata skip_if_present
test "$FETCHED" -eq 0
test ! -f "$TMP/recompile.txt"

# Too-small files must trigger fetch path (stub fails → overall fail)
dd if=/dev/zero of="$TMP/sbin/geosite.dat" bs=1 count=10 2>/dev/null
if update_community_geodata skip_if_present; then
  echo "expected fetch failure when files too small" >&2
  exit 1
fi
test "$FETCHED" -gt 0

echo "test-geodata-skip.sh OK"
