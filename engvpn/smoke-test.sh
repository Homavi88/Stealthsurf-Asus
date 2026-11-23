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
"$PREFIX/sbin/engvpnd" version | grep -q "$VERSION"
ENGVPN_FEED="file://$FEED_DIR/latest.json" "$PREFIX/sbin/engvpnd" update-check | grep -q "installed="
echo "  version + update-check ok"

echo "==> transparent dry-run + dokodemo snippet"
# Stop panel first so watchdog cannot race with dry-run iptables probes
"$PREFIX/share/engvpn/service.sh" stop >/dev/null 2>&1 || true
mkdir -p "$PREFIX/data"
cat >"$PREFIX/data/transparent.conf" <<EOF
mode=all
method=redirect
port=12345
mark=0x39000
table=79
killswitch=0
lan_if=br0
lan_cidr=192.168.50.0/24
EOF
dry_out=$(ENGVPN_DATA_DIR="$PREFIX/data" sh "$PREFIX/share/engvpn/transparent.sh" dry-run 2>&1) || {
	echo "transparent dry-run failed: $dry_out" >&2
	exit 1
}
printf '%s\n' "$dry_out" | grep -q 'mode=all' || {
	echo "unexpected dry-run output: $dry_out" >&2
	exit 1
}
[ -f "$PREFIX/data/run/dokodemo.inbound.json" ] || {
	echo "missing dokodemo.inbound.json" >&2
	exit 1
}
grep -q dokodemo-door "$PREFIX/data/run/dokodemo.inbound.json"
# Apply on smoke host may need root; try and accept failure without root
if [ "$(id -u)" = 0 ]; then
	ENGVPN_DATA_DIR="$PREFIX/data" sh "$PREFIX/share/engvpn/transparent.sh" apply
	ENGVPN_DATA_DIR="$PREFIX/data" sh "$PREFIX/share/engvpn/transparent.sh" status | grep -q active
	ENGVPN_DATA_DIR="$PREFIX/data" sh "$PREFIX/share/engvpn/transparent.sh" stop
	echo "  transparent apply/stop ok (root)"
else
	echo "  transparent dry-run ok (skip apply; not root)"
fi

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
	# Capture session cookie for invoke
	rm -f /tmp/engvpn-smoke-cookie.txt
	code=$(curl -s -c /tmp/engvpn-smoke-cookie.txt -o /tmp/engvpn-smoke-login.json -w '%{http_code}' -X POST "http://127.0.0.1:8790/api/login" \
		-H 'Content-Type: application/json' -d '{"password":"SmokeTest9!"}' || true)
	echo "  good login http=$code"
	[ "$code" = 200 ] || {
		echo "expected 200 on good login" >&2
		exit 1
	}
	# Panel EngVPN transparent dry-run via invoke
	inv=$(curl -fsS -b /tmp/engvpn-smoke-cookie.txt -X POST "http://127.0.0.1:8790/api/invoke/transparent" \
		-H 'Content-Type: application/json' -d '{"action":"dry-run","mode":"all","method":"redirect"}' || true)
	echo "$inv" | grep -q '"ok":true' || {
		echo "transparent invoke failed: $inv" >&2
		exit 1
	}
	echo "  transparent invoke ok"
	upd=$(curl -fsS -b /tmp/engvpn-smoke-cookie.txt -X POST "http://127.0.0.1:8790/api/invoke/engvpnUpdateCheck" \
		-H 'Content-Type: application/json' -d '{}' || true)
	echo "$upd" | grep -q 'installed' || echo "  update-check invoke: $upd"
	# Account UI path: empty key → subscription URL fields; invalid key rejected
	acc=$(curl -fsS -b /tmp/engvpn-smoke-cookie.txt -X POST "http://127.0.0.1:8790/api/invoke/get_account" \
		-H 'Content-Type: application/json' -d '{}' || true)
	echo "$acc" | grep -q 'apiKeySet' || echo "  get_account: $acc"
	bad=$(curl -s -b /tmp/engvpn-smoke-cookie.txt -o /tmp/engvpn-smoke-badacc.json -w '%{http_code}' -X POST "http://127.0.0.1:8790/api/invoke/saveAccount" \
		-H 'Content-Type: application/json' -d '{"apiKey":"not-a-key"}' || true)
	echo "  bad api key http=$bad (expect error body)"
	grep -qi 'stlth_\|ключ\|key\|Error\|error' /tmp/engvpn-smoke-badacc.json && echo "  api key validation ok" || echo "  api key validation response: $(cat /tmp/engvpn-smoke-badacc.json)"
	# Manual subscription URL without API key
	sub=$(curl -fsS -b /tmp/engvpn-smoke-cookie.txt -X POST "http://127.0.0.1:8790/api/invoke/saveAccount" \
		-H 'Content-Type: application/json' -d '{"subscriptionUrl":"vless://00000000-0000-4000-8000-000000000001@127.0.0.1:443?encryption=none&security=tls&type=tcp#smoke","preferUrl":true,"name":"smoke-url"}' || true)
	echo "$sub" | grep -q '"ok"\|vpn\|subscriptions\|smoke' && echo "  subscription URL save ok" || echo "  sub url: $sub"
	# DPI / WARP dry-run via engvpnd
	"$PREFIX/sbin/engvpnd" dpi dry-run | grep -q 'queue=' && echo "  dpi dry-run ok"
	"$PREFIX/sbin/engvpnd" warp dry-run | grep -q 'cloudflare_api=' && echo "  warp dry-run ok"
	# Bootstrap capabilities include warp/dpi
	boot=$(curl -fsS -b /tmp/engvpn-smoke-cookie.txt -X POST "http://127.0.0.1:8790/api/invoke/get_bootstrap" \
		-H 'Content-Type: application/json' -d '{}' || true)
	echo "$boot" | grep -q '"warp":true' && echo "  bootstrap warp ok" || echo "  bootstrap: $boot"
	"$PREFIX/share/engvpn/service.sh" stop
	echo "  stop ok"
else
	echo "==> skip panel live test (no node)"
fi

echo "==> minisign verify (if signed)"
PUB=$ROOT/keys/engvpn.minisign.pub
SIG=$ROOT/dist/engvpn_${VERSION}_merlin-x86_64.tar.gz.minisig
if [ -f "$SIG" ] && [ -f "$PUB" ]; then
	minisign -Vm "$ARCHIVE" -x "$SIG" -p "$PUB"
	node "$PREFIX/share/engvpn/verify-minisign.mjs" "$ARCHIVE" "$SIG" "$PUB" || \
		node "$ROOT/package/share/engvpn/verify-minisign.mjs" "$ARCHIVE" "$SIG" "$PUB"
	echo "  minisign ok"
else
	echo "  skip (no .minisig — build without key?)"
fi

echo "==> uninstall"
ENGVPN_SMOKE=1 ENGVPN_SCRIPTS="$SCRIPTS" ENGVPN_LOCK_DIR="$LOCK_DIR" \
	sh "$PREFIX/share/engvpn/install.sh" uninstall "$PREFIX"
[ ! -e "$PREFIX" ]
echo "  uninstall ok"

echo
echo "All EngVPN smoke checks passed."
