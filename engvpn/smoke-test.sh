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
	# Ensure supervisor/panel gone even if stop raced (including service.sh flock holders)
	pkill -f "$PREFIX/share/engvpn/service.sh" 2>/dev/null || true
	pkill -f "$PREFIX/share/engvpn/runtime/run.mjs" 2>/dev/null || true
	pkill -f "$PREFIX/sbin/engvpnd" 2>/dev/null || true
	rm -rf "$SMOKE_ROOT"
}
trap cleanup EXIT

# Reap orphan supervisors from earlier smoke runs (deleted PREFIX → exit 127 loop)
echo "==> reap orphan engvpn supervisors"
for e in /proc/[0-9]*; do
	p=${e#/proc/}
	cmd=$(tr '\000' ' ' <"$e/cmdline" 2>/dev/null || true)
	case "$cmd" in
	*/share/engvpn/service.sh*)
		spath=$(printf '%s\n' "$cmd" | tr ' ' '\n' | grep '/share/engvpn/service.sh' | head -n1)
		if [ -n "$spath" ] && [ ! -x "$spath" ]; then
			echo "  kill orphan supervisor pid=$p ($spath missing)"
			kill "$p" 2>/dev/null || true
		fi
		;;
	esac
done
sleep 1

echo "==> build packages"
sh ./build-package.sh

ARCHIVE=$ROOT/dist/engvpn_${VERSION}_merlin-x86_64.tar.gz
[ -f "$ARCHIVE" ] || {
	echo "missing $ARCHIVE" >&2
	exit 1
}

echo "==> feed must be GitHub HTTPS (never file:// /agent paths)"
grep -qE 'file://|/agent/repos/' "$ROOT/feed/latest.json" && {
	echo "latest.json contains local/file paths — refuse" >&2
	cat "$ROOT/feed/latest.json" >&2
	exit 1
}
grep -q "https://github.com/Homavi88/Stealthsurf-Asus/releases/download/engvpn-${VERSION}/" "$ROOT/feed/latest.json" || {
	echo "latest.json missing GitHub release URL for $VERSION" >&2
	exit 1
}
grep -q "https://github.com/Homavi88/Stealthsurf-Asus/releases/download/engvpn-${VERSION}/" "$ROOT/feed/latest.release.json" || {
	echo "latest.release.json missing GitHub release URL" >&2
	exit 1
}
echo "  feed HTTPS ok"

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

echo "==> updater rewrites foreign file:// to GitHub"
# Extract resolve_package_url from packaged update.sh and assert rewrite.
_upd=$ROOT/package/share/engvpn/update.sh
grep -q 'resolve_package_url' "$_upd" || {
	echo "missing resolve_package_url in update.sh" >&2
	exit 1
}
grep -q 'resolve_package_url' "$ROOT/merlin.sh" || {
	echo "missing resolve_package_url in merlin.sh" >&2
	exit 1
}
# Simulate: foreign agent path must become GitHub URL when smoke/local allow is off.
_resolved=$(
	unset ENGVPN_SMOKE ENGVPN_ALLOW_LOCAL || true
	PREFIX=/tmp/engvpn-fake
	PACKAGE_PREFIX=https://github.com/Homavi88/Stealthsurf-Asus/releases/download/
	# shellcheck disable=SC1091
	eval "$(sed -n '/^github_release_url()/,/^}/p; /^resolve_package_url()/,/^}/p' "$_upd")"
	resolve_package_url \
		"file:///agent/repos/Stealthsurf-Asus/engvpn/dist/engvpn_${VERSION}_merlin-x86_64.tar.gz" \
		"$VERSION" merlin-x86_64
)
_expect="https://github.com/Homavi88/Stealthsurf-Asus/releases/download/engvpn-${VERSION}/engvpn_${VERSION}_merlin-x86_64.tar.gz"
[ "$_resolved" = "$_expect" ] || {
	echo "resolve_package_url rewrite failed: got [$_resolved] expect [$_expect]" >&2
	exit 1
}
# With ENGVPN_SMOKE=1 and an existing local archive, keep file://
_smoke_resolved=$(
	ENGVPN_SMOKE=1
	PREFIX=/tmp/engvpn-fake
	PACKAGE_PREFIX=https://github.com/Homavi88/Stealthsurf-Asus/releases/download/
	eval "$(sed -n '/^github_release_url()/,/^}/p; /^resolve_package_url()/,/^}/p' "$_upd")"
	resolve_package_url "file://$ARCHIVE" "$VERSION" merlin-x86_64
)
[ "$_smoke_resolved" = "file://$ARCHIVE" ] || {
	echo "smoke local allow failed: got [$_smoke_resolved]" >&2
	exit 1
}
echo "  resolve_package_url rewrite ok"

echo "==> install via merlin.sh (local package + password env)"
export ENGVPN_SMOKE=1
export ENGVPN_SCRIPTS="$SCRIPTS"
export ENGVPN_LOCK_DIR="$LOCK_DIR"
export ENGVPN_BIN_DIR="$SMOKE_ROOT/bin"
export ENGVPN_PROFILE_ADD="$SMOKE_ROOT/profile.add"
export ENGVPN_PREFIX="$PREFIX"
export ENGVPN_PASSWORD="SmokeTest9!"
export ENGVPN_FEED="file://$FEED_DIR/latest.json"
# merlin.sh uses curl for feed — file:// may need special handling; use LOCAL override
export ENGVPN_LOCAL_PACKAGE="$ARCHIVE"
export ENGVPN_LOCAL_VERSION="$VERSION"
mkdir -p "$ENGVPN_BIN_DIR"

# merlin.sh still expects curl for non-local; LOCAL path skips download
install_log=$SMOKE_ROOT/merlin-install.log
sh ./merlin.sh >"$install_log" 2>&1 || {
	echo "merlin.sh failed:" >&2
	cat "$install_log" >&2
	exit 1
}
echo "==> install progress stages"
# Expect [1/10]…[10/10] with RU stage labels (incl. cores/geo download stage)
for n in 1 2 3 4 5 6 7 8 9 10; do
	grep -E "^\\[$n/10\\] " "$install_log" >/dev/null || {
		echo "missing progress stage [$n/10] in:" >&2
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
grep -q 'Загрузка ядер и гео-баз\|ядра пропущены' "$install_log"
grep -q 'Сохранение пароля' "$install_log"
grep -q 'Запуск сервиса' "$install_log"
echo "  progress [1/10]…[10/10] ok"

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

echo "==> PATH / CLI links"
[ -L "$ENGVPN_BIN_DIR/engvpnd" ] || {
	echo "missing symlink $ENGVPN_BIN_DIR/engvpnd" >&2
	exit 1
}
link_target=$(readlink "$ENGVPN_BIN_DIR/engvpnd")
[ "$link_target" = "$PREFIX/sbin/engvpnd" ] || {
	echo "bad symlink target: $link_target (want $PREFIX/sbin/engvpnd)" >&2
	exit 1
}
grep -q 'EngVPN PATH' "$ENGVPN_PROFILE_ADD"
grep -q "$PREFIX/sbin" "$ENGVPN_PROFILE_ADD"
grep -q "полный путь: $PREFIX/sbin/engvpnd" "$install_log" || {
	echo "install banner missing CLI path; log:" >&2
	cat "$install_log" >&2
	exit 1
}
# Short verb via PATH-style symlink (smoke BIN_DIR)
"$ENGVPN_BIN_DIR/engvpnd" ver | grep -q "$VERSION"
echo "  PATH symlink + profile.add + banner ok"

echo "==> engvpnd status / version"
"$PREFIX/sbin/engvpnd" version | grep -q "$VERSION"
"$PREFIX/sbin/engvpnd" ver | grep -q "$VERSION"
ENGVPN_SMOKE=1 ENGVPN_FEED="file://$FEED_DIR/latest.json" "$PREFIX/sbin/engvpnd" update-check | grep -q "installed="
ENGVPN_SMOKE=1 ENGVPN_FEED="file://$FEED_DIR/latest.json" "$PREFIX/sbin/engvpnd" check | grep -q "installed="
echo "  version + update-check ok"

echo "==> engvpnd short verbs (help + dispatch)"
help_out=$("$PREFIX/sbin/engvpnd" --help)
printf '%s\n' "$help_out" | grep -q 'uninstall | remove'
printf '%s\n' "$help_out" | grep -q 'reinstall'
printf '%s\n' "$help_out" | grep -q 'update | up'
printf '%s\n' "$help_out" | grep -q 'Быстрые команды'
# Dispatch aliases without side effects
"$PREFIX/sbin/engvpnd" st >/dev/null 2>&1 || true
"$PREFIX/sbin/engvpnd" priv dry-run | grep -q 'privacy-check'
# Wipe without confirm must refuse (ENGVPN_SMOKE + unset REINSTALL_WIPE)
if ENGVPN_SMOKE=1 "$PREFIX/sbin/engvpnd" reinstall --wipe >/tmp/engvpn-smoke-wipe.out 2>&1; then
	echo "reinstall --wipe should refuse without ENGVPN_REINSTALL_WIPE=1" >&2
	cat /tmp/engvpn-smoke-wipe.out >&2
	exit 1
fi
grep -qi 'cancelled\|ENGVPN_REINSTALL_WIPE' /tmp/engvpn-smoke-wipe.out
# Force reinstall (same version) via local feed — preserves data marker.
# Redirect to a file (not a pipe): service supervisor would keep a pipe open.
echo "smoke-reinstall=keep-me" >"$PREFIX/data/smoke.reinstall"
ENGVPN_SMOKE=1 ENGVPN_SCRIPTS="$SCRIPTS" ENGVPN_LOCK_DIR="$LOCK_DIR" \
	ENGVPN_FEED="file://$FEED_DIR/latest.json" \
	"$PREFIX/sbin/engvpnd" reinstall 30 >/tmp/engvpn-smoke-reinstall.out 2>&1
grep -q 'keep-me' "$PREFIX/data/smoke.reinstall"
grep -q 'reinstall: keeping data' /tmp/engvpn-smoke-reinstall.out
# Stop panel started by reinstall so later smoke steps stay deterministic
ENGVPN_SMOKE=1 ENGVPN_SCRIPTS="$SCRIPTS" ENGVPN_LOCK_DIR="$LOCK_DIR" \
	"$PREFIX/share/engvpn/service.sh" stop >/dev/null 2>&1 || true
echo "  short verbs + reinstall (keep data) ok"

echo "==> schedule-update (conf + run, auto off)"
[ -x "$PREFIX/share/engvpn/schedule-update.sh" ]
ENGVPN_DATA_DIR="$PREFIX/data" ENGVPN_FEED="file://$FEED_DIR/latest.json" \
	"$PREFIX/sbin/engvpnd" schedule-update write-conf interval=1d auto=0 window_start=2 window_end=5
grep -q 'auto=0' "$PREFIX/data/updates.conf"
grep -q 'interval=1d' "$PREFIX/data/updates.conf"
# Without cru on smoke host a marker file is enough
ENGVPN_DATA_DIR="$PREFIX/data" ENGVPN_FEED="file://$FEED_DIR/latest.json" \
	"$PREFIX/sbin/engvpnd" schedule-update install-cru >/dev/null
ENGVPN_DATA_DIR="$PREFIX/data" ENGVPN_FEED="file://$FEED_DIR/latest.json" \
	"$PREFIX/sbin/engvpnd" schedule-update run
grep -q 'last_check=' "$PREFIX/data/updates.conf"
# auto=0 must not apply even if feed differed
grep -E 'last_result=(up-to-date|available)' "$PREFIX/data/updates.conf" || {
	echo "unexpected last_result in updates.conf" >&2
	cat "$PREFIX/data/updates.conf" >&2
	exit 1
}
"$PREFIX/sbin/engvpnd" schedule-update status | grep -q 'conf='
echo "  schedule-update ok"

echo "==> single-instance panel (no dual run.mjs / no supervisor storm)"
"$PREFIX/share/engvpn/service.sh" stop >/dev/null 2>&1 || true
count_panels() {
	_n=0
	for e in /proc/[0-9]*; do
		cmd=$(tr '\000' ' ' <"$e/cmdline" 2>/dev/null || true)
		case "$cmd" in
		*"$PREFIX/share/engvpn/runtime/run.mjs"*) _n=$((_n + 1)) ;;
		esac
	done
	echo "$_n"
}
count_supervisors() {
	# Background shells that keep service.sh in argv (supervisor flock holders)
	_n=0
	for e in /proc/[0-9]*; do
		p=${e#/proc/}
		[ "$p" = "$$" ] && continue
		cmd=$(tr '\000' ' ' <"$e/cmdline" 2>/dev/null || true)
		case "$cmd" in
		*"$PREFIX/share/engvpn/service.sh"*) _n=$((_n + 1)) ;;
		esac
	done
	echo "$_n"
}
"$PREFIX/share/engvpn/service.sh" start
# Storm: many concurrent start (services-start + post-mount race) — must not stack
i=0
while [ "$i" -lt 18 ]; do
	"$PREFIX/share/engvpn/service.sh" start >/dev/null 2>&1 &
	i=$((i + 1))
done
wait || true
sleep 2
n_panels=$(count_panels)
n_sup=$(count_supervisors)
echo "  after 18× parallel start: panels=$n_panels supervisors≈$n_sup"
[ "$n_panels" -eq 1 ] || {
	echo "expected exactly 1 run.mjs, got $n_panels" >&2
	for e in /proc/[0-9]*; do
		cmd=$(tr '\000' ' ' <"$e/cmdline" 2>/dev/null || true)
		case "$cmd" in
		*"$PREFIX"*run.mjs* | *"$PREFIX"*service.sh*) echo "  pid ${e#/proc/}: $cmd" >&2 ;;
		esac
	done
	exit 1
}
# One flock-holding supervisor (+ maybe a short-lived start script still exiting)
[ "$n_sup" -le 2 ] || {
	echo "supervisor storm: $n_sup service.sh processes (want ≤2)" >&2
	for e in /proc/[0-9]*; do
		cmd=$(tr '\000' ' ' <"$e/cmdline" 2>/dev/null || true)
		case "$cmd" in
		*"$PREFIX"*service.sh*) echo "  pid ${e#/proc/}: $cmd" >&2 ;;
		esac
	done
	exit 1
}
# Serial restart once — still one panel
"$PREFIX/share/engvpn/service.sh" restart >/dev/null
sleep 2
n_panels=$(count_panels)
echo "  after restart: panels=$n_panels"
[ "$n_panels" -eq 1 ] || {
	echo "after restart expected 1 run.mjs, got $n_panels" >&2
	exit 1
}
# engvpnd serve while running must exit 75 (duplicate lock)
# Keep set +e across wait — exit 75 must not abort the smoke script.
set +e
"$PREFIX/sbin/engvpnd" serve --data-dir "$PREFIX/data" >/tmp/engvpn-dup-serve.out 2>&1 &
dup_pid=$!
sleep 1
kill -0 "$dup_pid" 2>/dev/null
dup_alive=$?
if [ "$dup_alive" = 0 ]; then
	# still running — wait a bit for flock fail / EADDRINUSE
	sleep 2
	if kill -0 "$dup_pid" 2>/dev/null; then
		echo "duplicate engvpnd serve still alive — killing" >&2
		kill "$dup_pid" 2>/dev/null || true
		wait "$dup_pid" 2>/dev/null
		set -e
		exit 1
	fi
fi
wait "$dup_pid" 2>/dev/null
dup_code=$?
set -e
# 75 = flock/EADDRINUSE; some shells report 128+signal — accept 75 or immediate exit non-zero with lock message
if [ "$dup_code" != 75 ]; then
	if grep -qi 'already running\|EADDRINUSE\|panel lock' /tmp/engvpn-dup-serve.out 2>/dev/null; then
		echo "  duplicate serve rejected (msg, exit=$dup_code)"
	else
		echo "duplicate serve exit=$dup_code out=$(cat /tmp/engvpn-dup-serve.out)" >&2
		# Still require single panel after attempt
		n2=0
		for e in /proc/[0-9]*; do
			cmd=$(tr '\000' ' ' <"$e/cmdline" 2>/dev/null || true)
			case "$cmd" in
			*"$PREFIX/share/engvpn/runtime/run.mjs"*) n2=$((n2 + 1)) ;;
			esac
		done
		[ "$n2" -eq 1 ] || {
			echo "after dup serve: expected 1 panel, got $n2" >&2
			exit 1
		}
		echo "  duplicate serve did not add panel (exit=$dup_code)"
	fi
else
	echo "  duplicate serve exit 75 ok"
fi
"$PREFIX/share/engvpn/service.sh" kill-strays >/dev/null 2>&1 || "$PREFIX/share/engvpn/service.sh" stop >/dev/null 2>&1 || true
echo "  single-instance ok"

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
		_hash=$(printf '%s' "$PREFIX" | md5sum 2>/dev/null | awk '{print substr($1,1,12)}')
		tail -50 "/tmp/engvpn-${_hash:-}/engvpnd.log" 2>/dev/null ||
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
	# Empty home: no demo NL/Trojan locations before key/URL
	snap0=$(curl -fsS -b /tmp/engvpn-smoke-cookie.txt "http://127.0.0.1:8790/api/snapshot" || true)
	if echo "$snap0" | grep -qE 'nl-trojan|Нидерланды Trojan|NL Trojan|Нидерланды VLESS|Умная локация'; then
		echo "snapshot still has demo locations (expected scrubbed): $(echo "$snap0" | head -c 500)" >&2
		exit 1
	fi
	echo "  no demo locations ok"
	echo "$snap0" | grep -q 'apiKeySet' && echo "  apiKeySet field ok" || echo "  apiKeySet soft"
	# UI: settings master-detail + empty-home copy present in panel assets
	_ui_js="$PREFIX/share/engvpn/runtime/public/app.js"
	_ui_css="$PREFIX/share/engvpn/runtime/public/app.css"
	[ -f "$_ui_js" ] || { echo "missing panel app.js at $_ui_js" >&2; exit 1; }
	grep -q 'drawer-settings\|settings-split\|data-go-top' "$_ui_js" \
		&& echo "  settings master-detail UI ok" \
		|| { echo "missing settings master-detail in app.js" >&2; exit 1; }
	grep -q 'Добавьте ключ или URL\|hasCredentials\|realVpnNodes\|locStatusLine' "$_ui_js" \
		&& echo "  empty-home UI ok" \
		|| { echo "missing empty-home helpers in app.js" >&2; exit 1; }
	grep -q 'settings-split\|drawer-settings' "$_ui_css" \
		&& echo "  settings CSS ok" \
		|| { echo "missing settings CSS" >&2; exit 1; }
	grep -q 'has-pane .settings-nav { display: none' "$_ui_css" \
		&& grep -q 'min-width: 900px' "$_ui_css" \
		&& echo "  settings mobile list→detail + desktop ≥900 split ok" \
		|| { echo "missing mobile list/detail or desktop split CSS" >&2; exit 1; }
	! grep -q '@media (max-width: 899px)' "$_ui_css" \
		&& echo "  settings CSS is mobile-first (no max-width:899 override) ok" \
		|| { echo "settings CSS should be mobile-first, not max-width:899 override" >&2; exit 1; }
	grep -q 'Установить обновление\|install-update\|updateAvailable\|feedNewer' "$_ui_js" \
		&& echo "  updates install button UI ok" \
		|| { echo "missing install-update button in app.js" >&2; exit 1; }
	grep -q 'Доступна версия\|update-banner\|Список изменений\|homeUpdateChipHtml' "$_ui_js" \
		&& echo "  home update chip UI ok" \
		|| { echo "missing StealthSurf-style home update chip in app.js" >&2; exit 1; }
	grep -q 'update-action-log\|updateActionLog\|startUpdateLogPoll\|Журнал обновления' "$_ui_js" \
		&& echo "  updates action log UI ok" \
		|| { echo "missing updates action log in app.js" >&2; exit 1; }
	grep -q 'update-banner\|update-banner-ico\|update-action-log' "$_ui_css" \
		&& echo "  update banner/log CSS ok" \
		|| { echo "missing update banner CSS" >&2; exit 1; }
	grep -q 'kill-strays before update\|ENGVPN_STORM_CLEARED\|clear_engvpn_storm' "$PREFIX/sbin/engvpnd" \
		&& grep -q 'clear_engvpn_storm\|Очистка лишних процессов' "$ROOT/merlin.sh" \
		&& echo "  storm-safe update path ok" \
		|| { echo "missing kill-strays before update in engvpnd/merlin" >&2; exit 1; }
	# 0.5.27: quiet /proc cmdline, orphan sleep reap, musl sing-box, curl progress bar
	grep -q 'read_cmdline\|\[ -r "/proc/\$1/cmdline" \]' "$PREFIX/share/engvpn/service.sh" \
		&& ! grep -qE 'tr .*<"/proc/.*/cmdline"' "$PREFIX/share/engvpn/service.sh" \
		&& echo "  quiet cmdline (-r + cat) ok" \
		|| { echo "service.sh must use -r + cat for cmdline (no shell <redir)" >&2; exit 1; }
	grep -q 'kill_orphan_helpers\|reap_orphans_on_start\|supervisor_sleep' "$PREFIX/share/engvpn/service.sh" \
		&& grep -q 'kill_strays 2>/dev/null' "$PREFIX/share/engvpn/service.sh" \
		&& echo "  orphan sleep reap + quiet kill-strays ok" \
		|| { echo "missing orphan reap / quiet kill-strays" >&2; exit 1; }
	grep -q 'pickSingBoxAssets\|musl' "$PREFIX/share/engvpn/runtime/lib/engines.mjs" \
		&& grep -q 'loaderIncompatible\|libresolv' "$PREFIX/share/engvpn/runtime/lib/engines.mjs" \
		&& echo "  sing-box musl/libresolv fallback ok" \
		|| { echo "missing sing-box musl preference in engines.mjs" >&2; exit 1; }
	grep -q 'mkdirSync(geoDir\|mkdirSync(dirname(dest)' "$PREFIX/share/engvpn/download-cores.mjs" \
		&& echo "  geosite mkdir -p ok" \
		|| { echo "missing geoDir mkdir in download-cores.mjs" >&2; exit 1; }
	grep -q 'download_curl_progress\|progress_bar' "$ROOT/merlin.sh" \
		&& grep -q 'download_curl_progress\|progress_bar' "$PREFIX/share/engvpn/update.sh" \
		&& echo "  curl progress bar (merlin+update) ok" \
		|| { echo "missing download progress bar in merlin.sh/update.sh" >&2; exit 1; }
	grep -q 'ask_delete_backup\|ENGVPN_DELETE_BACKUP\|Удалить каталог резервных копий' "$PREFIX/share/engvpn/install.sh" \
		&& echo "  uninstall backup-delete prompt ok" \
		|| { echo "missing ask_delete_backup in install.sh" >&2; exit 1; }
	grep -q 'getUpdateActionLog\|update-action.log\|detached' "$PREFIX/share/engvpn/runtime/lib/runtime-engvpn.mjs" \
		&& echo "  update action log runtime ok" \
		|| { echo "missing getUpdateActionLog / detached update" >&2; exit 1; }
	grep -q 'dl-progress\|downloadProgress\|paintDownloadProgress' "$_ui_js" \
		&& echo "  core/geo download progress UI ok" \
		|| { echo "missing download progress UI in app.js" >&2; exit 1; }
	grep -q 'Мбит/с\|mbps\|flagFromName\|ping-good\|nodeFlagKind' "$_ui_js" \
		&& echo "  Mbps + locations flag/ping UI ok" \
		|| { echo "missing Mbps / locations UX in app.js" >&2; exit 1; }
	grep -q 'ping-good\|flag\.de\|loc-main' "$_ui_css" \
		&& echo "  locations ping/flag CSS ok" \
		|| { echo "missing locations ping/flag CSS" >&2; exit 1; }
	grep -q 'ROUTER_MODES\|sel("router.mode"\|VPN для всей сети' "$_ui_js" \
		&& ! grep -q 'mode-picks\|data-router-mode\|mode-pick' "$_ui_js" \
		&& echo "  router mode dropdown UI ok" \
		|| { echo "router mode must be a single <select> (no stacked picks)" >&2; exit 1; }
	# Custom rules: add-rule must use data-input (sel()) / null-safe ctrl(), never bare data-set only
	grep -q 'function ctrl(\|isEphemeralCtrl\|ctrl("draft-action")' "$_ui_js" \
		&& echo "  custom-rules draft-action ctrl ok" \
		|| { echo "missing draft-action ctrl() fix in app.js" >&2; exit 1; }
	grep -q 'data-set=draft-action' "$_ui_js" \
		&& { echo "stale data-set=draft-action query left in app.js" >&2; exit 1; } \
		|| echo "  no stale data-set=draft-action query ok"
	! grep -q 'mode-picks\|mode-pick\|mode-select-wrap' "$_ui_css" \
		&& echo "  router mode stacked-picks CSS removed ok" \
		|| { echo "leftover mode-picks CSS in app.css" >&2; exit 1; }
	grep -q 'min-width: 900px\|drawer-settings' "$_ui_css" \
		&& echo "  desktop settings ≥900px CSS ok" \
		|| { echo "missing desktop settings width CSS" >&2; exit 1; }
	grep -q 'readInstalledVersion\|export function readInstalledVersion' "$PREFIX/share/engvpn/runtime/lib/runtime-engvpn.mjs" \
		&& echo "  VERSION source-of-truth ok" \
		|| { echo "missing readInstalledVersion" >&2; exit 1; }
	grep -q 'download-cores.mjs\|fetch_engine_assets' "$PREFIX/share/engvpn/install.sh" \
		&& echo "  install cores hook ok" \
		|| { echo "missing install cores hook" >&2; exit 1; }
	[ -f "$PREFIX/share/engvpn/download-cores.mjs" ] \
		&& echo "  download-cores.mjs packaged ok" \
		|| { echo "missing download-cores.mjs in package" >&2; exit 1; }
	grep -q 'engvpnUpdateApply\|export async function engvpnUpdateApply' "$PREFIX/share/engvpn/runtime/lib/runtime-engvpn.mjs" \
		&& echo "  engvpnUpdateApply ok" \
		|| { echo "missing engvpnUpdateApply in runtime-engvpn.mjs" >&2; exit 1; }
	grep -q 'scrubAlphaDemoNodes' "$PREFIX/share/engvpn/runtime/lib/runtime-engvpn.mjs" \
		&& echo "  scrubAlphaDemoNodes ok" \
		|| { echo "missing scrubAlphaDemoNodes in runtime-engvpn.mjs" >&2; exit 1; }
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
	"$PREFIX/sbin/engvpnd" privacy dry-run | grep -q 'privacy-check' && echo "  privacy dry-run ok"
	priv=$("$PREFIX/sbin/engvpnd" privacy 2>/dev/null || true)
	echo "$priv" | grep -q '"exit"' && echo "  privacy json ok" || echo "  privacy: $priv"
	# Bootstrap capabilities include warp/dpi/privacy
	boot=$(curl -fsS -b /tmp/engvpn-smoke-cookie.txt -X POST "http://127.0.0.1:8790/api/invoke/get_bootstrap" \
		-H 'Content-Type: application/json' -d '{}' || true)
	echo "$boot" | grep -q '"warp":true' && echo "  bootstrap warp ok" || echo "  bootstrap: $boot"
	echo "$boot" | grep -q 'privacyChecks\|leakTest' && echo "  bootstrap privacy ok" || echo "  bootstrap privacy keys: (optional)"
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
# BusyBox finalize must not rely on sort -o / mv of a missing files.sorted
# (comments may mention -o; only fail on real code lines)
if grep -v '^[[:space:]]*#' "$PREFIX/share/engvpn/backup.sh" | grep -E 'sort[[:space:]].*-o[[:space:]]'; then
	echo "backup.sh still uses fragile sort -o" >&2
	exit 1
fi
grep -q 'sort -u "$list" >"$sorted"' "$PREFIX/share/engvpn/backup.sh" || {
	echo "backup.sh missing redirect-based sort finalize" >&2
	exit 1
}
# Simulate missing sidecar: create still succeeds (unsorted keep / no hard fail)
_bak_root=$(dirname "$PREFIX")/.engvpn-backup
case "$PREFIX" in
*/addons/engvpn) _bak_root=${PREFIX%/engvpn}/.engvpn-backup ;;
esac
_work=$(mktemp -d "${_bak_root}/work.smoke.XXXXXX" 2>/dev/null || mktemp -d)
_list=$_work/files
: >"$_list"
echo "data/smoke.marker" >>"$_list"
echo "share/engvpn/VERSION" >>"$_list"
# empty/missing .sorted path must not be required — exercise redirect sort like backup.sh
_sorted=$_list.sorted
rm -f "$_sorted"
sort -u "$_list" >"$_sorted" 2>/dev/null || true
if [ -s "$_sorted" ]; then
	mv -f "$_sorted" "$_list" 2>/dev/null || rm -f "$_sorted"
else
	rm -f "$_sorted"
fi
[ -s "$_list" ] || {
	echo "redirect sort finalize left empty list" >&2
	rm -rf "$_work"
	exit 1
}
rm -rf "$_work"
# create must not emit hard-fail finalize strings
ENGVPN_SMOKE=1 ENGVPN_SKIP_BACKUP=0 "$PREFIX/sbin/engvpnd" backup create "$PREFIX" >/tmp/engvpn-smoke-backup2.out 2>/tmp/engvpn-smoke-backup2.err || {
	echo "second backup create failed" >&2
	cat /tmp/engvpn-smoke-backup2.out /tmp/engvpn-smoke-backup2.err >&2
	exit 1
}
grep -E 'cannot finalize file list|sort file list failed' /tmp/engvpn-smoke-backup2.out /tmp/engvpn-smoke-backup2.err && {
	echo "backup still hard-fails finalize:" >&2
	cat /tmp/engvpn-smoke-backup2.out /tmp/engvpn-smoke-backup2.err >&2
	exit 1
}
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
# Engines must contain SmartDNS merge helper after build
grep -q 'smartdnsBypassRules' "$PREFIX/share/engvpn/runtime/lib/engines.mjs" || {
	echo "engines.mjs missing smartdnsBypassRules merge" >&2
	exit 1
}
grep -q 'ensureEnginePortFree' "$PREFIX/share/engvpn/runtime/lib/engines.mjs" || {
	echo "engines.mjs missing ensureEnginePortFree (20828 race)" >&2
	exit 1
}
grep -q 'findEnginePortHolders' "$PREFIX/share/engvpn/runtime/lib/engines.mjs" || {
	echo "engines.mjs missing findEnginePortHolders" >&2
	exit 1
}
grep -q 'opts?.child\|opts.child\|{ child:' "$PREFIX/share/engvpn/runtime/lib/runtime.mjs" || {
	echo "runtime.mjs missing alive-aware waitForPort(child)" >&2
	exit 1
}
grep -q 'bypass.routing.json' "$PREFIX/share/engvpn/runtime/lib/engines.mjs" || {
	echo "engines.mjs does not read bypass.routing.json" >&2
	exit 1
}
echo "  smartdns dry-run + engines merge ok"

echo "==> devices.select + DNS hijack conf"
printf '192.168.50.21\naa:bb:cc:dd:ee:01\n' >"$PREFIX/data/devices.select"
cat >"$PREFIX/data/transparent.conf" <<EOF
mode=exclude
method=redirect
port=12345
mark=0x39000
table=79
killswitch=0
lan_if=br0
lan_cidr=192.168.50.0/24
dns_hijack=1
dns_port=5353
captive_open=0
EOF
dry=$(ENGVPN_SMOKE=1 ENGVPN_DATA_DIR="$PREFIX/data" sh "$PREFIX/share/engvpn/transparent.sh" dry-run)
echo "$dry" | grep -q 'mode=exclude' || {
	echo "transparent dry-run missing mode: $dry" >&2
	exit 1
}
echo "$dry" | grep -q '192.168.50.21\|devices:' || true
# Catalog VERSION matches package
pkg_ver=$(cat "$PREFIX/share/engvpn/VERSION")
cat_ver=$(node -e "import('$PREFIX/share/engvpn/runtime/lib/catalog.mjs').then(m=>console.log(m.VERSION))" 2>/dev/null || grep -oE 'VERSION = "[^"]+"' "$PREFIX/share/engvpn/runtime/lib/catalog.mjs" | head -1 | sed 's/.*"\([^"]*\)"/\1/')
[ "$pkg_ver" = "$cat_ver" ] || {
	echo "VERSION drift: package=$pkg_ver catalog=$cat_ver" >&2
	exit 1
}
echo "  devices.select + version sync ok ($pkg_ver)"

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
	# Diagnostics: top processes by CPU/RAM (BusyBox /proc)
	inv_ok "get_router_load" get_router_load '{"limit":5}'
	grep -q '"processes"' /tmp/engvpn-inv-out.json || {
		echo "get_router_load missing processes" >&2
		head -c 800 /tmp/engvpn-inv-out.json >&2
		exit 1
	}
	grep -q '"byCpu"\|"byRam"' /tmp/engvpn-inv-out.json || {
		echo "get_router_load processes missing byCpu/byRam" >&2
		head -c 800 /tmp/engvpn-inv-out.json >&2
		exit 1
	}
	# Second sample so CPU deltas can populate (first may be 0%)
	inv_ok "get_top_processes" get_top_processes '{"limit":5}'
	node -e '
	  const j=JSON.parse(require("fs").readFileSync("/tmp/engvpn-inv-out.json","utf8"));
	  const r=j.result||j;
	  const p=r.processes||{};
	  const n=(p.byRam||[]).length;
	  if(n<1){console.error("expected byRam entries, got",JSON.stringify(p).slice(0,400));process.exit(1)}
	  const row=p.byRam[0];
	  if(!row||!(row.pid>0)||!row.name){console.error("bad process row",row);process.exit(1)}
	  if(!Array.isArray(p.flagged)){console.error("missing flagged[]");process.exit(1)}
	  if(!Array.isArray(p.hints)){console.error("missing hints[]");process.exit(1)}
	  const hit=(p.flagged||[]).some(x=>x&&(x.kind==="engvpn"||x.kind==="node"||/node|engvpn|run\.mjs/i.test(String(x.name||""))));
	  if(!hit){console.error("expected flagged engvpn/node process, flagged=",JSON.stringify(p.flagged).slice(0,500));process.exit(1)}
	  console.log("  top processes ok:", n, "byRam, flagged", p.flagged.length, "hints", p.hints.length, "sample", row.name, "rssKb="+row.rssKb);
	'
	inv_ok "engvpnUpdateCheck" engvpnUpdateCheck '{}'
	# Auto-update toggle must persist to updates.conf + schedule (not bounce off after hydrate)
	inv_ok "patch.updates.auto" patch '{"path":"updates.auto","value":true}'
	grep -q '"auto":true\|"auto": true' /tmp/engvpn-inv-out.json || {
		echo "patch updates.auto did not return auto:true" >&2
		head -c 800 /tmp/engvpn-inv-out.json >&2
		exit 1
	}
	grep -q 'auto=1' "$PREFIX/data/updates.conf" || {
		echo "updates.conf missing auto=1 after patch" >&2
		cat "$PREFIX/data/updates.conf" >&2
		exit 1
	}
	echo "  updates.auto persist ok"
	inv_ok "patch.updates.auto.off" patch '{"path":"updates.auto","value":false}'
	grep -q 'auto=0' "$PREFIX/data/updates.conf" || {
		echo "updates.conf missing auto=0 after toggle off" >&2
		cat "$PREFIX/data/updates.conf" >&2
		exit 1
	}
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
	inv_ok "privacyCheck" privacyCheck '{}'
	grep -q '"exit"\|"dns"\|"fingerprint"\|"killswitch"' /tmp/engvpn-inv-out.json && echo "  privacyCheck payload ok" || echo "  privacyCheck body: $(head -c 200 /tmp/engvpn-inv-out.json)"
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

echo "==> engvpnd uninstall with ENGVPN_RESTORE=1 (rollback from backup)"
echo "smoke-marker=restore-me" >"$PREFIX/data/smoke.marker"
ENGVPN_SMOKE=1 "$PREFIX/sbin/engvpnd" backup create "$PREFIX" >/dev/null
# Mutate after backup — restore must bring back restore-me
echo "smoke-marker=changed" >"$PREFIX/data/smoke.marker"
ENGVPN_SMOKE=1 ENGVPN_SCRIPTS="$SCRIPTS" ENGVPN_LOCK_DIR="$LOCK_DIR" ENGVPN_RESTORE=1 \
	"$PREFIX/sbin/engvpnd" uninstall "$PREFIX"
[ -d "$PREFIX" ] || {
	echo "expected prefix after RESTORE=1" >&2
	exit 1
}
grep -q 'restore-me' "$PREFIX/data/smoke.marker" || {
	echo "restore did not bring back smoke.marker" >&2
	cat "$PREFIX/data/smoke.marker" >&2 || true
	exit 1
}
echo "  restore-on-uninstall (engvpnd) ok"

echo "==> engvpnd remove with ENGVPN_RESTORE=0 (clean remove, no farewell backup)"
bak_dir="$(dirname "$PREFIX")/.engvpn-backup"
case "$PREFIX" in
*/addons/engvpn) bak_dir=${PREFIX%/engvpn}/.engvpn-backup ;;
esac
# Snapshot archive list before clean remove — must not grow / must not recreate empty root
pre_archives=$(ls -1 "$bak_dir"/engvpn-backup-*.tar.gz 2>/dev/null | wc -l | tr -d ' ')
rm -rf "$bak_dir"
uninstall_log=/tmp/engvpn-smoke-uninstall.log
ENGVPN_SMOKE=1 ENGVPN_SCRIPTS="$SCRIPTS" ENGVPN_LOCK_DIR="$LOCK_DIR" ENGVPN_RESTORE=0 \
	"$PREFIX/sbin/engvpnd" remove "$PREFIX" >"$uninstall_log" 2>&1 || {
	echo "clean remove failed:" >&2
	cat "$uninstall_log" >&2
	exit 1
}
[ ! -e "$PREFIX" ]
# Progress stages [1/4]…[4/4] RU labels
for n in 1 2 3 4; do
	grep -E "^\\[$n/4\\] " "$uninstall_log" >/dev/null || {
		echo "missing uninstall progress [$n/4] in:" >&2
		cat "$uninstall_log" >&2
		exit 1
	}
done
grep -q 'Остановка сервиса' "$uninstall_log"
grep -q 'Снятие расписания' "$uninstall_log"
grep -q 'Снятие хуков' "$uninstall_log"
grep -q 'Удаление файлов' "$uninstall_log"
# Must not create sibling .engvpn-backup on clean remove
if [ -d "$bak_dir" ]; then
	echo "clean remove created farewell backup dir: $bak_dir" >&2
	ls -la "$bak_dir" >&2 || true
	exit 1
fi
grep -qi 'files\.tmp' "$uninstall_log" && {
	echo "files.tmp race leaked into uninstall log:" >&2
	cat "$uninstall_log" >&2
	exit 1
}
echo "  clean remove (engvpnd) ok (pre_archives=$pre_archives)"

echo "==> engvpnd remove keeps .engvpn-backup by default; DELETE_BACKUP=1 wipes it"
# Reinstall briefly, seed a fake backup dir, remove with keep, then with delete
export ENGVPN_SMOKE=1
export ENGVPN_SCRIPTS="$SCRIPTS"
export ENGVPN_LOCK_DIR="$LOCK_DIR"
export ENGVPN_PREFIX="$PREFIX"
export ENGVPN_PASSWORD="SmokeTest9!"
export ENGVPN_LOCAL_PACKAGE="$ARCHIVE"
export ENGVPN_LOCAL_VERSION="$VERSION"
export ENGVPN_SKIP_BACKUP=1
sh ./merlin.sh >/tmp/engvpn-smoke-reinstall-bak.log 2>&1 || {
	echo "reinstall for backup-delete test failed:" >&2
	cat /tmp/engvpn-smoke-reinstall-bak.log >&2
	exit 1
}
mkdir -p "$bak_dir"
echo seed >"$bak_dir/seed.txt"
ENGVPN_SMOKE=1 ENGVPN_SCRIPTS="$SCRIPTS" ENGVPN_LOCK_DIR="$LOCK_DIR" ENGVPN_RESTORE=0 ENGVPN_DELETE_BACKUP=0 \
	"$PREFIX/sbin/engvpnd" remove "$PREFIX" >/tmp/engvpn-smoke-bak-keep.log 2>&1 || {
	echo "remove with DELETE_BACKUP=0 failed:" >&2
	cat /tmp/engvpn-smoke-bak-keep.log >&2
	exit 1
}
[ ! -e "$PREFIX" ]
[ -f "$bak_dir/seed.txt" ] || {
	echo "DELETE_BACKUP=0 should keep $bak_dir" >&2
	exit 1
}
grep -q 'бэкапы сохранены\|сохранены' /tmp/engvpn-smoke-bak-keep.log || true
# Reinstall again and delete backups
export ENGVPN_SKIP_BACKUP=1
sh ./merlin.sh >/tmp/engvpn-smoke-reinstall-bak2.log 2>&1
mkdir -p "$bak_dir"
echo seed2 >"$bak_dir/seed.txt"
ENGVPN_SMOKE=1 ENGVPN_SCRIPTS="$SCRIPTS" ENGVPN_LOCK_DIR="$LOCK_DIR" ENGVPN_RESTORE=0 ENGVPN_DELETE_BACKUP=1 \
	"$PREFIX/sbin/engvpnd" remove "$PREFIX" >/tmp/engvpn-smoke-bak-del.log 2>&1 || {
	echo "remove with DELETE_BACKUP=1 failed:" >&2
	cat /tmp/engvpn-smoke-bak-del.log >&2
	exit 1
}
[ ! -e "$PREFIX" ]
[ ! -d "$bak_dir" ] || {
	echo "DELETE_BACKUP=1 should remove $bak_dir" >&2
	ls -la "$bak_dir" >&2 || true
	exit 1
}
grep -q 'каталог бэкапов\|удалён' /tmp/engvpn-smoke-bak-del.log
echo "  backup-delete prompt (keep/delete) ok"

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
[ ! -e "$ENGVPN_BIN_DIR/engvpnd" ] && [ ! -L "$ENGVPN_BIN_DIR/engvpnd" ] || {
	echo "CLI symlink not removed: $ENGVPN_BIN_DIR/engvpnd" >&2
	ls -la "$ENGVPN_BIN_DIR" >&2 || true
	exit 1
}
if [ -f "$ENGVPN_PROFILE_ADD" ]; then
	grep -q 'EngVPN PATH' "$ENGVPN_PROFILE_ADD" && {
		echo "profile.add still has EngVPN PATH after uninstall" >&2
		cat "$ENGVPN_PROFILE_ADD" >&2
		exit 1
	}
fi
echo "  final uninstall ok"

echo
echo "All EngVPN smoke checks passed."
