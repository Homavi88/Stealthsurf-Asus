#!/bin/sh
# EngVPN Merlin smoke tests — runnable on a cloud/dev Linux host (no real router).
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$ROOT"

VERSION=$(cat VERSION)
SMOKE_ROOT=/tmp/engvpn-smoke-$$
PREFIX=$SMOKE_ROOT/engvpn
SCRIPTS=$SMOKE_ROOT/scripts
LOCK_DIR=$SMOKE_ROOT/lock
FEED_DIR=$SMOKE_ROOT/feed

cleanup() {
	ENGVPN_SMOKE=1 ENGVPN_SCRIPTS="$SCRIPTS" ENGVPN_LOCK_DIR="$LOCK_DIR" \
		"$PREFIX/share/engvpn/service.sh" stop >/dev/null 2>&1 || true
	rm -rf "$SMOKE_ROOT"
}
trap cleanup EXIT

echo "==> build packages"
sh ./build-package.sh

ARCHIVE=$ROOT/dist/engvpn_${VERSION}_merlin-x86_64.tar.gz
[ -f "$ARCHIVE" ] || {
	echo "missing $ARCHIVE" >&2
	exit 1
}

mkdir -p "$SCRIPTS" "$LOCK_DIR" "$FEED_DIR"
# Point feed at local archive
sum=$(sha256sum "$ARCHIVE" | awk '{ print $1 }')
size=$(wc -c <"$ARCHIVE" | tr -d ' ')
cat >"$FEED_DIR/latest.json" <<EOF
{
  "version": "$VERSION",
  "notes": "smoke",
  "packages": {
    "merlin-x86_64": {
      "url": "file://$ARCHIVE",
      "sha256": "$sum",
      "size": $size
    }
  }
}
EOF

echo "==> shell syntax"
for f in merlin.sh package/sbin/engvpnd package/share/engvpn/*.sh; do
	sh -n "$f"
	echo "  ok $f"
done

echo "==> install via merlin.sh (local package + password env)"
export ENGVPN_SMOKE=1
export ENGVPN_SCRIPTS="$SCRIPTS"
export ENGVPN_LOCK_DIR="$LOCK_DIR"
export ENGVPN_PREFIX="$PREFIX"
export ENGVPN_PASSWORD="SmokeTest9!"
export ENGVPN_FEED="file://$FEED_DIR/latest.json"
# merlin.sh uses curl for feed — file:// may need special handling; use LOCAL override
export ENGVPN_LOCAL_PACKAGE="$ARCHIVE"
export ENGVPN_LOCAL_VERSION="$VERSION"

# merlin.sh still expects curl for non-local; LOCAL path skips download
sh ./merlin.sh

echo "==> verify layout"
[ -x "$PREFIX/sbin/engvpnd" ]
[ -f "$PREFIX/share/engvpn/install.sh" ]
[ -f "$PREFIX/share/engvpn/files" ]
[ -f "$PREFIX/data/state.json" ]
grep -q 'pbkdf2-sha256' "$PREFIX/data/state.json"
echo "  layout + password hash ok"

echo "==> hooks present"
grep -q 'EngVPN' "$SCRIPTS/services-start"
grep -q 'EngVPN' "$SCRIPTS/firewall-start"
echo "  hooks ok"

echo "==> engvpnd status / version"
"$PREFIX/sbin/engvpnd" version | grep -q .
"$PREFIX/sbin/engvpnd" update-check | grep -q "installed="

if command -v node >/dev/null 2>&1; then
	echo "==> start panel (node available)"
	"$PREFIX/share/engvpn/service.sh" start
	# health endpoint
	ok=0
	i=0
	while [ "$i" -lt 20 ]; do
		if curl -fsS "http://127.0.0.1:8790/api/health" 2>/dev/null | grep -q '"ok":true'; then
			ok=1
			break
		fi
		sleep 1
		i=$((i + 1))
	done
	[ "$ok" = 1 ] || {
		echo "panel health failed; log:" >&2
		tail -50 /tmp/engvpn/engvpnd.log 2>/dev/null || true
		exit 1
	}
	echo "  health ok"
	# unauthenticated invoke should fail when OPEN_PANEL=0
	code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:8790/api/login" \
		-H 'Content-Type: application/json' -d '{"password":"wrong-password-xx"}' || true)
	echo "  bad login http=$code"
	code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:8790/api/login" \
		-H 'Content-Type: application/json' -d '{"password":"SmokeTest9!"}' || true)
	echo "  good login http=$code"
	[ "$code" = 200 ] || {
		echo "expected 200 on good login" >&2
		exit 1
	}
	"$PREFIX/share/engvpn/service.sh" stop
	echo "  stop ok"
else
	echo "==> skip panel live test (no node)"
fi

echo "==> uninstall"
ENGVPN_SMOKE=1 ENGVPN_SCRIPTS="$SCRIPTS" ENGVPN_LOCK_DIR="$LOCK_DIR" \
	sh "$PREFIX/share/engvpn/install.sh" uninstall "$PREFIX"
[ ! -e "$PREFIX" ]
echo "  uninstall ok"

echo
echo "All EngVPN smoke checks passed."
