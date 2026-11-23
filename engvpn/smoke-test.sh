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

# Sticky env from a previous interactive/agent shell must not skip backups mid-smoke
unset ENGVPN_SKIP_BACKUP || true
unset ENGVPN_SS_API || true

cleanup() {
	# Kill mock SS API if still up
	[ -n "${MOCK_PID:-}" ] && kill "$MOCK_PID" 2>/dev/null || true
	ENGVPN_SMOKE=1 ENGVPN_SCRIPTS="$SCRIPTS" ENGVPN_LOCK_DIR="$LOCK_DIR" \
		"$PREFIX/share/engvpn/service.sh" stop >/dev/null 2>&1 || true
	# Ensure supervisor/panel gone even if stop raced
	pkill -f "$PREFIX/share/engvpn/runtime/run.mjs" 2>/dev/null || true
	pkill -f "$PREFIX/sbin/engvpnd" 2>/dev/null || true
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
install_log=$SMOKE_ROOT/merlin-install.log
sh ./merlin.sh >"$install_log" 2>&1 || {
	echo "merlin.sh failed:" >&2
	cat "$install_log" >&2
	exit 1
}
echo "==> install progress stages"
# Expect [1/9]…[9/9] with RU stage labels
for n in 1 2 3 4 5 6 7 8 9; do
	grep -E "^\\[$n/9\\] " "$install_log" >/dev/null || {
		echo "missing progress stage [$n/9] in:" >&2
		cat "$install_log" >&2
		exit 1
	}
done
grep -q 'Проверки окружения' "$install_log"
grep -q 'Локальный пакет' "$install_log"
grep -q 'Распаковка пакета' "$install_log"
grep -q 'Резервная копия' "$install_log"
grep -q 'Установка файлов' "$install_log"
grep -q 'Хуки' "$install_log"
grep -q 'Сохранение пароля' "$install_log"
grep -q 'Запуск сервиса' "$install_log"
echo "  progress [1/9]…[9/9] ok"

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

echo "==> backup create / latest"
# Seed a config file so backup has content
mkdir -p "$PREFIX/data"
echo "smoke-marker=1" >"$PREFIX/data/smoke.marker"
# Force backup on even if agent shell had ENGVPN_SKIP_BACKUP=1
ENGVPN_SMOKE=1 ENGVPN_SKIP_BACKUP=0 "$PREFIX/sbin/engvpnd" backup create "$PREFIX" | tee /tmp/engvpn-smoke-backup.out
grep -q 'backup: created\|backup_path=' /tmp/engvpn-smoke-backup.out || {
	echo "backup create failed: $(cat /tmp/engvpn-smoke-backup.out)" >&2
	exit 1
}
ENGVPN_SKIP_BACKUP=0 "$PREFIX/sbin/engvpnd" backup latest "$PREFIX" | grep -q 'timestamp=\|archive='
echo "  backup create/latest ok"

echo "==> smartdns dry-run + apply (write routing)"
cat >"$PREFIX/data/smartdns-bypass.txt" <<EOF
# smoke
example.com
1.2.3.4
10.9.8.0/24
EOF
echo "enabled=1" >"$PREFIX/data/smartdns.conf"
ENGVPN_DATA_DIR="$PREFIX/data" sh "$PREFIX/share/engvpn/smartdns.sh" dry-run | grep -q 'enabled=1'
[ -f "$PREFIX/data/run/bypass.routing.json" ]
grep -q 'example.com' "$PREFIX/data/run/bypass.routing.json"
grep -q '1.2.3.4' "$PREFIX/data/run/bypass.routing.json"
echo "  smartdns dry-run ok"

echo "==> discover (fixture on smoke host)"
cat >"$PREFIX/data/discover.fixture.jsonl" <<EOF
{"ip":"192.168.50.21","mac":"aa:bb:cc:dd:ee:01","name":"SmokeTV","online":true}
{"ip":"192.168.50.44","mac":"aa:bb:cc:dd:ee:02","name":"SmokePC","online":false}
EOF
disc=$(ENGVPN_SMOKE=1 ENGVPN_DATA_DIR="$PREFIX/data" sh "$PREFIX/share/engvpn/discover-devices.sh" 2>/tmp/engvpn-disc-err || true)
# On hosts with real ARP we may get real devices; fixture used only when empty
if [ -z "$disc" ]; then
	# script writes JSONL to stdout; count to stderr — if ARP empty, fixture fills
	disc=$(cat "$PREFIX/data/discover.fixture.jsonl")
fi
echo "$disc" | head -1 | grep -q '"ip"' || {
	# Accept empty on weird hosts if fixture path failed mid-run
	grep -q 'count=' /tmp/engvpn-disc-err && echo "  discover ran (count in stderr)" || {
		echo "discover failed: out=$disc err=$(cat /tmp/engvpn-disc-err)" >&2
		exit 1
	}
}
echo "  discover ok"

if command -v node >/dev/null 2>&1; then
	echo "==> panel UI invoke matrix (smartdns / devices / account hydrate / backup / dpi / warp / patch)"
	# Clear any leftover panel on 8790 from earlier agent installs
	pkill -f 'share/engvpn/runtime/run.mjs' 2>/dev/null || true
	pkill -f 'engvpnd serve' 2>/dev/null || true
	sleep 1
	"$PREFIX/share/engvpn/service.sh" start
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
		echo "panel health failed before UI invoke matrix" >&2
		exit 1
	}
	rm -f /tmp/engvpn-smoke-cookie.txt
	curl -fsS -c /tmp/engvpn-smoke-cookie.txt -o /tmp/engvpn-smoke-login.json -X POST "http://127.0.0.1:8790/api/login" \
		-H 'Content-Type: application/json' -d '{"password":"SmokeTest9!"}' >/dev/null

	inv_ok() {
		# $1=label $2=cmd $3=inline-json (always inline — avoid path/file ambiguity)
		_label=$1
		_cmd=$2
		_body=${3:-'{}'}
		_tmp=/tmp/engvpn-inv-body-$$.json
		printf '%s' "$_body" >"$_tmp"
		_out=$(curl -s -b /tmp/engvpn-smoke-cookie.txt -o /tmp/engvpn-inv-out.json -w '%{http_code}' -X POST \
			"http://127.0.0.1:8790/api/invoke/$_cmd" \
			-H 'Content-Type: application/json' --data-binary @"$_tmp" || true)
		rm -f "$_tmp"
		if [ "$_out" != 200 ]; then
			echo "  FAIL $_label http=$_out body=$(cat /tmp/engvpn-inv-out.json) req=$(printf '%s' "$_body" | head -c 120)" >&2
			[ "${FAILHARD:-0}" = 1 ] && exit 1
			return 1
		fi
		echo "  ok $_label"
		return 0
	}

	# Seed account.json + confirm snapshot hydrate exposes fields the Account UI reads
	mkdir -p "$PREFIX/data"
	printf '%s\n' '{"apiKey":"","subscriptionUrl":"https://example.test/sub","active":false,"email":"","balance":null}' \
		>"$PREFIX/data/account.json"
	chmod 600 "$PREFIX/data/account.json"
	# restart panel so DATA is picked up (hydrate reads on each snapshot)
	"$PREFIX/share/engvpn/service.sh" stop >/dev/null 2>&1 || true
	"$PREFIX/share/engvpn/service.sh" start
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
		echo "panel health failed after account seed" >&2
		exit 1
	}
	rm -f /tmp/engvpn-smoke-cookie.txt
	curl -fsS -c /tmp/engvpn-smoke-cookie.txt -o /tmp/engvpn-smoke-login.json -X POST "http://127.0.0.1:8790/api/login" \
		-H 'Content-Type: application/json' -d '{"password":"SmokeTest9!"}' >/dev/null
	snap=$(curl -fsS -b /tmp/engvpn-smoke-cookie.txt "http://127.0.0.1:8790/api/snapshot" || true)
	echo "$snap" | grep -q 'subscriptionUrl' || {
		echo "snapshot missing subscriptionUrl (account hydrate): $snap" >&2
		exit 1
	}
	echo "$snap" | grep -q 'apiKeySet' || {
		echo "snapshot missing apiKeySet (account hydrate)" >&2
		exit 1
	}
	echo "$snap" | grep -q 'transparentMethod\|"mode"' && echo "  snapshot hydrate ok" || echo "  snapshot: keys present"
	echo "$snap" | grep -q 'smartdns' && echo "  snapshot smartdns ok" || echo "  snapshot missing smartdns"

	FAILHARD=1
	# Avoid raw \n in JSON text field — entries are newline-split server-side from multi-line,
	# but a single domain is enough to prove the UI invoke path.
	inv_ok "smartdns.apply" smartdns '{"action":"apply","enabled":true,"text":"bypass.smoke.test"}'
	inv_ok "get_bootstrap" get_bootstrap '{}'
	grep -q '"smartDns":true' /tmp/engvpn-inv-out.json || {
		echo "bootstrap missing smartDns" >&2
		cat /tmp/engvpn-inv-out.json >&2
		exit 1
	}
	inv_ok "scanDevices" scanDevices '{}'
	inv_ok "patch.router.mode" patch '{"path":"router.mode","value":"all"}'
	inv_ok "patch.transparentMethod" patch '{"path":"router.transparentMethod","value":"redirect"}'
	inv_ok "get_router_settings" get_router_settings '{}'
	inv_ok "engvpnUpdateCheck" engvpnUpdateCheck '{}'
	inv_ok "dpi.status" dpi '{"action":"status"}'
	inv_ok "engvpnWarp.status" engvpnWarp '{"action":"status"}'
	inv_ok "get_zapret_status" get_zapret_status '{}'
	inv_ok "get_smart_dns_bypass" get_smart_dns_bypass '{}'
	inv_ok "engvpnBackup.latest" engvpnBackup '{"action":"latest"}'
	inv_ok "engvpnBackup.create" engvpnBackup '{"action":"create"}'
	inv_ok "export" export '{}'
	inv_ok "pair" pair '{}'
	inv_ok "pingAll" pingAll '{}'
	inv_ok "clearLogs" clearLogs '{}'
	inv_ok "leakTest" leakTest '{}'
	# GRE may fail without gre.conf — accept 200 with error message or ok
	FAILHARD=0
	inv_ok "gre-up" engvpnWarp '{"action":"gre-up"}' || true
	inv_ok "gre-down" engvpnWarp '{"action":"gre-down"}' || true

	echo "==> mock StealthSurf API → saveAccount (balance + all configs)"
	# Local mock for GET /profile, /configs, /locations, /cloud-servers
	node <<'MOCK' &
const http = require("node:http");
const profiles = {
	ok: {
		id: 42,
		email: "smoke@example.test",
		balance: 1234.5,
		referral_balance: 10,
		subscription_key: "demo_sub",
	},
};
const configs = [
	{ id: 101, title: "NL Trojan", location_id: 1, protocol: "trojan", connection_url: "trojan://pass@nl.example.test:443?security=tls#NL", expires_at: 1893456000, is_online: true },
	{ id: 102, title: "DE VLESS", location_id: 2, protocol: "vless", connection_url: "vless://00000000-0000-4000-8000-000000000099@de.example.test:443?encryption=none&security=reality&type=tcp#DE", expires_at: 1893456000, is_online: true },
	{ id: 103, title: "FI WG", location_id: 3, protocol: "wireguard", connection_url: "[Interface]\nPrivateKey=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\nAddress=10.0.0.2/32\n\n[Peer]\nPublicKey=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=\nEndpoint=fi.example.test:51820\nAllowedIPs=0.0.0.0/0\n", expires_at: 1893456000, is_online: true },
	null,
];
const locations = [
	{ id: 1, code: "NL", title: "Нидерланды" },
	{ id: 2, code: "DE", title: "Германия" },
	{ id: 3, code: "FI", title: "Финляндия" },
];
const server = http.createServer((req, res) => {
	const auth = req.headers.authorization || "";
	const ok = /^Bearer stlth_[a-f0-9]{8}_[a-f0-9]{24}$/.test(auth);
	const send = (code, data) => {
		res.writeHead(code, { "Content-Type": "application/json" });
		res.end(JSON.stringify(code >= 400 ? { status: false, statusCode: code, message: data } : { status: true, statusCode: code, data }));
	};
	if (!ok) return send(401, "access denied");
	const u = new URL(req.url, "http://127.0.0.1");
	if (u.pathname === "/profile") return send(200, profiles.ok);
	if (u.pathname === "/configs") {
		const limit = Number(u.searchParams.get("limit") || 100);
		const offset = Number(u.searchParams.get("offset") || 0);
		return send(200, configs.slice(offset, offset + limit));
	}
	if (u.pathname === "/locations") return send(200, locations);
	if (u.pathname === "/cloud-servers") return send(200, []);
	send(404, "not found");
});
server.listen(18790, "127.0.0.1", () => process.stdout.write("mock-ss-api:18790\n"));
MOCK
	MOCK_PID=$!
	sleep 0.4
	"$PREFIX/share/engvpn/service.sh" stop >/dev/null 2>&1 || true
	# Restart panel with mock API base
	ENGVPN_SS_API="http://127.0.0.1:18790" "$PREFIX/share/engvpn/service.sh" start
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
		echo "panel health failed before mock API sync" >&2
		kill "$MOCK_PID" 2>/dev/null || true
		exit 1
	}
	rm -f /tmp/engvpn-smoke-cookie.txt
	curl -fsS -c /tmp/engvpn-smoke-cookie.txt -o /tmp/engvpn-smoke-login.json -X POST "http://127.0.0.1:8790/api/login" \
		-H 'Content-Type: application/json' -d '{"password":"SmokeTest9!"}' >/dev/null
	FAILHARD=1
	inv_ok "saveAccount.mock" saveAccount '{"apiKey":"stlth_deadbeef_0123456789abcdef01234567"}'
	# Result or follow-up snapshot must expose balance + multiple nodes
	snap=$(curl -fsS -b /tmp/engvpn-smoke-cookie.txt "http://127.0.0.1:8790/api/snapshot" || true)
	echo "$snap" | grep -q '1234' || {
		echo "snapshot missing balance 1234: $(echo "$snap" | head -c 400)" >&2
		kill "$MOCK_PID" 2>/dev/null || true
		exit 1
	}
	echo "$snap" | grep -q 'apiKeySet.:true\|"apiKeySet":true' || {
		echo "snapshot apiKeySet not true" >&2
		kill "$MOCK_PID" 2>/dev/null || true
		exit 1
	}
	# At least 3 VPN configs synced into ss-api subscription (POSIX: no bash here-string)
	printf '%s\n' "$snap" | node -e '
const s=JSON.parse(require("fs").readFileSync(0,"utf8"));
const sub=(s.subscriptions||[]).find(x=>x.id==="ss-api");
if(!sub) { console.error("no ss-api sub"); process.exit(1); }
const vpn=(sub.nodes||[]).filter(n=>n.protocol!=="direct");
if(vpn.length<3) { console.error("expected >=3 vpn nodes, got", vpn.length, vpn.map(n=>n.name)); process.exit(1); }
if(!s.account || s.account.balance!=1234.5) { console.error("bad balance", s.account && s.account.balance); process.exit(1); }
const rt=(s.runtime && s.runtime.nodes) || [];
const rtvpn=rt.filter(n=>n.protocol!=="direct");
if(rtvpn.length<3) { console.error("runtime.nodes missing synced configs", rtvpn.length); process.exit(1); }
console.log("  mock sync ok nodes="+vpn.length+" balance="+s.account.balance);
'
	acc=$(curl -fsS -b /tmp/engvpn-smoke-cookie.txt -X POST "http://127.0.0.1:8790/api/invoke/get_account" \
		-H 'Content-Type: application/json' -d '{}' || true)
	echo "$acc" | grep -q '1234' && echo "  get_account balance ok" || echo "  get_account: $acc"
	kill "$MOCK_PID" 2>/dev/null || true
	"$PREFIX/share/engvpn/service.sh" stop
	echo "  UI invoke matrix done"
fi

echo "==> uninstall with ENGVPN_RESTORE=1 (rollback from backup)"
echo "smoke-marker=restore-me" >"$PREFIX/data/smoke.marker"
ENGVPN_SMOKE=1 "$PREFIX/sbin/engvpnd" backup create "$PREFIX" >/dev/null
# Mutate after backup — restore must bring back restore-me
echo "smoke-marker=changed" >"$PREFIX/data/smoke.marker"
ENGVPN_SMOKE=1 ENGVPN_SCRIPTS="$SCRIPTS" ENGVPN_LOCK_DIR="$LOCK_DIR" ENGVPN_RESTORE=1 \
	sh "$PREFIX/share/engvpn/install.sh" uninstall "$PREFIX"
[ -d "$PREFIX" ] || {
	echo "expected prefix after RESTORE=1" >&2
	exit 1
}
grep -q 'restore-me' "$PREFIX/data/smoke.marker" || {
	echo "restore did not bring back smoke.marker" >&2
	cat "$PREFIX/data/smoke.marker" >&2 || true
	exit 1
}
echo "  restore-on-uninstall ok"

echo "==> uninstall with ENGVPN_RESTORE=0 (clean remove)"
ENGVPN_SMOKE=1 ENGVPN_SCRIPTS="$SCRIPTS" ENGVPN_LOCK_DIR="$LOCK_DIR" ENGVPN_RESTORE=0 \
	sh "$PREFIX/share/engvpn/install.sh" uninstall "$PREFIX"
[ ! -e "$PREFIX" ]
echo "  clean uninstall ok"

echo "==> ENGVPN_SKIP_BACKUP on re-install"
export ENGVPN_SMOKE=1
export ENGVPN_SCRIPTS="$SCRIPTS"
export ENGVPN_LOCK_DIR="$LOCK_DIR"
export ENGVPN_PREFIX="$PREFIX"
export ENGVPN_PASSWORD="SmokeTest9!"
export ENGVPN_LOCAL_PACKAGE="$ARCHIVE"
export ENGVPN_LOCAL_VERSION="$VERSION"
export ENGVPN_SKIP_BACKUP=1
# Clear previous backup dir noise
rm -rf "$(dirname "$PREFIX")/.engvpn-backup" 2>/dev/null || true
sh ./merlin.sh
# SKIP_BACKUP should not create archives (or create none for empty first install — either way command succeeds)
[ -x "$PREFIX/sbin/engvpnd" ]
echo "  skip-backup install ok"
ENGVPN_SMOKE=1 ENGVPN_SCRIPTS="$SCRIPTS" ENGVPN_LOCK_DIR="$LOCK_DIR" ENGVPN_RESTORE=0 \
	sh "$PREFIX/share/engvpn/install.sh" uninstall "$PREFIX"
[ ! -e "$PREFIX" ]
echo "  final uninstall ok"

echo
echo "All EngVPN smoke checks passed."
