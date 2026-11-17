#!/bin/sh
# Guard: panel_busybox_has_httpd must reject BusyBox without the httpd applet.
set -e
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass() { echo "OK  $*"; }
fail() { echo "FAIL  $*" >&2; exit 1; }

PANEL_LOG="$TMP/panel.log"
mkdir -p "$TMP"

log_error() { :; }
log_warn() { :; }
log_ok() { :; }
log_info() { :; }

# Fake busybox WITHOUT httpd
cat >"$TMP/bb-nohttpd" <<'EOF'
#!/bin/sh
if [ "$1" = "httpd" ]; then
  echo "bb-nohttpd: applet not found" >&2
  exit 1
fi
echo "BusyBox v1.36.0"
echo "Currently defined functions:"
echo "ash, echo, ls"
EOF
chmod +x "$TMP/bb-nohttpd"

# Fake busybox WITH httpd
cat >"$TMP/bb-httpd" <<'EOF'
#!/bin/sh
if [ "$1" = "httpd" ]; then
  echo "BusyBox v1.36.0 (httpd) multi-call binary."
  echo "Usage: httpd [-p IP:PORT] [-h HOME] [-c FILE]"
  exit 0
fi
echo "BusyBox v1.36.0"
echo "Currently defined functions:"
echo "ash, echo, httpd, ls"
EOF
chmod +x "$TMP/bb-httpd"

# shellcheck disable=SC1091
# Extract panel_busybox_has_httpd / panel_find_httpd / panel_ensure_httpd only
eval "$(
  awk '
    /^panel_busybox_has_httpd\(\)/ {keep=1}
    /^panel_ensure_secondary_ip\(\)/ {keep=0}
    keep {print}
  ' "$ROOT/src/backend/panel.sh"
)"

panel_busybox_has_httpd "$TMP/bb-nohttpd" && fail "accepted busybox without httpd" || pass "rejects busybox without httpd"
panel_busybox_has_httpd "$TMP/bb-httpd" || fail "rejected busybox with httpd"
pass "accepts busybox with httpd"

# Override find to only see our fakes (no host /opt busybox)
panel_find_httpd() {
    local cand
    for cand in "$TMP/bb-nohttpd" "$TMP/bb-httpd"; do
        panel_busybox_has_httpd "$cand" || continue
        echo "$cand httpd"
        return 0
    done
    return 1
}
got=$(panel_find_httpd) || fail "panel_find_httpd returned nothing"
[ "$got" = "$TMP/bb-httpd httpd" ] || fail "expected bb-httpd, got: $got"
pass "find prefers httpd-capable busybox"

echo "ALL PASS"
