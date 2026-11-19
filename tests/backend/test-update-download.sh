#!/bin/sh
# Ensure package update uses github_download (mirrors + Entware HTTPS), not BusyBox wget --show-progress.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
UPD="$ROOT/src/backend/update.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

grep -q 'github_download' "$UPD" || fail "update() must call github_download"
grep -q 'github_https_bin' "$UPD" || fail "update() should mention github_https_bin in errors"
# regression: package fetch must not invoke bare wget (BusyBox / wrong flags)
if grep -E '^[[:space:]]*wget[[:space:]]' "$UPD" >/dev/null 2>&1; then
    fail "update() must not call wget directly — use github_download"
fi

echo "ok: update download uses github_download"
