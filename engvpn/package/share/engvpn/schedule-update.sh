#!/bin/sh
# EngVPN scheduled update-check (+ optional auto-apply) via Merlin cru / cron.
#
#   schedule-update.sh run              # check feed; apply if auto=1 (and in window)
#   schedule-update.sh install-cru      # (re)register durable cru/cron from updates.conf
#   schedule-update.sh remove-cru       # drop cru/cron job
#   schedule-update.sh status           # print conf + job state
#   schedule-update.sh write-conf …     # write key=value pairs into updates.conf
#
# Durable across reboot: services-start / install re-call install-cru (cru is RAM-only on Merlin).
set -u

SHARE=$(cd "${0%/*}" 2>/dev/null && pwd -P) || exit 1
PREFIX=${SHARE%/share/engvpn}
DAEMON=$PREFIX/sbin/engvpnd
DATA_DIR=${ENGVPN_DATA_DIR:-$PREFIX/data}
CONF=$DATA_DIR/updates.conf
LOG=${ENGVPN_UPDATE_LOG:-/tmp/engvpn-update-check.log}
CRU_ID=engvpn_upd
PATH=/opt/bin:/opt/sbin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}
export PATH

# Defaults: periodic check on, auto-apply off
DEFAULT_INTERVAL=1d
DEFAULT_AUTO=0
DEFAULT_WINDOW_START=2
DEFAULT_WINDOW_END=5

fail() {
	echo "schedule-update: $*" >&2
	exit 1
}

ensure_data() {
	mkdir -p "$DATA_DIR" 2>/dev/null || true
	chmod 700 "$DATA_DIR" 2>/dev/null || true
}

# shellcheck disable=SC2034
conf_get() {
	key=$1
	def=$2
	[ -f "$CONF" ] || {
		echo "$def"
		return 0
	}
	val=$(awk -F= -v k="$key" '$1==k { print substr($0, index($0,"=")+1); exit }' "$CONF" 2>/dev/null)
	[ -n "$val" ] && echo "$val" || echo "$def"
}

conf_set_many() {
	ensure_data
	# Load existing
	interval=$(conf_get interval "$DEFAULT_INTERVAL")
	auto=$(conf_get auto "$DEFAULT_AUTO")
	window_start=$(conf_get window_start "$DEFAULT_WINDOW_START")
	window_end=$(conf_get window_end "$DEFAULT_WINDOW_END")
	geo_weekly=$(conf_get geo_weekly 1)
	cores_when_missing=$(conf_get cores_when_missing 1)
	last_check=$(conf_get last_check "")
	last_result=$(conf_get last_result "")
	# Apply argv key=value
	for pair in "$@"; do
		case "$pair" in
		*=*)
			k=${pair%%=*}
			v=${pair#*=}
			case "$k" in
			interval) interval=$v ;;
			auto) auto=$v ;;
			window_start | windowStart) window_start=$v ;;
			window_end | windowEnd) window_end=$v ;;
			geo_weekly | geoWeekly) geo_weekly=$v ;;
			cores_when_missing | coresWhenMissing) cores_when_missing=$v ;;
			last_check | lastCheck) last_check=$v ;;
			last_result | lastResult) last_result=$v ;;
			esac
			;;
		esac
	done
	# Normalize booleans
	case "$auto" in 1 | true | TRUE | yes | on) auto=1 ;; *) auto=0 ;; esac
	case "$geo_weekly" in 1 | true | TRUE | yes | on) geo_weekly=1 ;; *) geo_weekly=0 ;; esac
	case "$cores_when_missing" in 1 | true | TRUE | yes | on) cores_when_missing=1 ;; *) cores_when_missing=0 ;; esac
	case "$interval" in 6h | 12h | 1d | 3d | 7d | off | disabled) ;; *) interval=$DEFAULT_INTERVAL ;; esac
	umask 077
	cat >"$CONF.tmp" <<EOF
interval=$interval
auto=$auto
window_start=$window_start
window_end=$window_end
geo_weekly=$geo_weekly
cores_when_missing=$cores_when_missing
last_check=$last_check
last_result=$last_result
EOF
	mv -f "$CONF.tmp" "$CONF"
}

ensure_conf() {
	ensure_data
	[ -f "$CONF" ] || conf_set_many
}

cron_expr_for() {
	case "$1" in
	6h) echo "17 */6 * * *" ;;
	12h) echo "23 */12 * * *" ;;
	1d) echo "29 4 * * *" ;;
	3d) echo "31 4 */3 * *" ;;
	7d) echo "37 4 * * 0" ;;
	*) echo "" ;;
	esac
}

have_cru() {
	command -v cru >/dev/null 2>&1
}

remove_cru() {
	if have_cru; then
		cru d "$CRU_ID" 2>/dev/null || true
	fi
	# Fallback crontab line marker
	if command -v crontab >/dev/null 2>&1; then
		tmp=/tmp/engvpn-cron.$$
		crontab -l 2>/dev/null | grep -vF "# $CRU_ID" >"$tmp" 2>/dev/null || true
		crontab "$tmp" 2>/dev/null || true
		rm -f "$tmp"
	fi
	# Smoke / no-cru: drop helper marker
	rm -f "$DATA_DIR/.update-cron" 2>/dev/null || true
}

install_cru() {
	ensure_conf
	interval=$(conf_get interval "$DEFAULT_INTERVAL")
	remove_cru
	expr=$(cron_expr_for "$interval")
	if [ -z "$expr" ]; then
		echo "schedule-update: interval=$interval — job not installed"
		return 0
	fi
	cmd="[ -x \"$SHARE/schedule-update.sh\" ] && \"$SHARE/schedule-update.sh\" run"
	if have_cru; then
		cru a "$CRU_ID" "$expr $cmd" || fail "cru a $CRU_ID failed"
		echo "schedule-update: cru $CRU_ID installed ($interval → $expr)"
	elif command -v crontab >/dev/null 2>&1; then
		tmp=/tmp/engvpn-cron.$$
		{
			crontab -l 2>/dev/null | grep -vF "# $CRU_ID" || true
			echo "$expr $cmd # $CRU_ID"
		} >"$tmp"
		crontab "$tmp" || {
			rm -f "$tmp"
			fail "crontab install failed"
		}
		rm -f "$tmp"
		echo "schedule-update: crontab $CRU_ID installed ($interval → $expr)"
	else
		# Persist desired schedule for smoke / hosts without cru; services-start will retry.
		printf '%s\n' "$expr $cmd" >"$DATA_DIR/.update-cron"
		echo "schedule-update: no cru/crontab — wrote $DATA_DIR/.update-cron ($interval)"
	fi
}

in_night_window() {
	start=$(conf_get window_start "$DEFAULT_WINDOW_START")
	end=$(conf_get window_end "$DEFAULT_WINDOW_END")
	# Force hour via ENGVPN_FORCE_HOUR for tests
	hour=${ENGVPN_FORCE_HOUR:-$(date +%H 2>/dev/null | sed 's/^0//')}
	hour=${hour:-0}
	start=${start:-0}
	end=${end:-24}
	# Window may wrap midnight (e.g. 22–5)
	if [ "$start" -le "$end" ]; then
		[ "$hour" -ge "$start" ] && [ "$hour" -lt "$end" ]
	else
		[ "$hour" -ge "$start" ] || [ "$hour" -lt "$end" ]
	fi
}

record_result() {
	ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)
	conf_set_many "last_check=$ts" "last_result=$1"
}

cmd_run() {
	ensure_conf
	interval=$(conf_get interval "$DEFAULT_INTERVAL")
	auto=$(conf_get auto "$DEFAULT_AUTO")
	case "$interval" in
	off | disabled)
		echo "schedule-update: checks disabled"
		record_result "disabled"
		return 0
		;;
	esac
	: >>"$LOG" 2>/dev/null || true
	{
		echo "---- $(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date) interval=$interval auto=$auto ----"
		if [ -x "$DAEMON" ]; then
			out=$("$DAEMON" update-check 2>&1) || true
		elif [ -x "$SHARE/update.sh" ]; then
			out=$(sh "$SHARE/update.sh" check 2>&1) || true
		else
			echo "schedule-update: no engvpnd/update.sh"
			record_result "missing"
			return 1
		fi
		printf '%s\n' "$out"
		avail=$(printf '%s\n' "$out" | sed -n 's/^update_available=//p' | head -n 1)
		feed=$(printf '%s\n' "$out" | sed -n 's/^feed=//p' | head -n 1)
		if [ "$avail" != 1 ]; then
			record_result "up-to-date${feed:+:$feed}"
			echo "schedule-update: up to date"
			return 0
		fi
		echo "schedule-update: update available (feed=$feed)"
		if [ "$auto" != 1 ]; then
			record_result "available:$feed"
			echo "schedule-update: auto=0 — check only"
			return 0
		fi
		if ! in_night_window; then
			record_result "available-wait-window:$feed"
			echo "schedule-update: outside night window — defer apply"
			return 0
		fi
		echo "schedule-update: auto-apply via engvpnd update"
		if [ -x "$DAEMON" ]; then
			"$DAEMON" update 90 2>&1 || {
				record_result "apply-failed:$feed"
				return 1
			}
		else
			sh "$SHARE/update.sh" apply 90 2>&1 || {
				record_result "apply-failed:$feed"
				return 1
			}
		fi
		record_result "applied:$feed"
		echo "schedule-update: applied $feed"
	} >>"$LOG" 2>&1
}

cmd_status() {
	ensure_conf
	echo "conf=$CONF"
	[ -f "$CONF" ] && cat "$CONF"
	if have_cru; then
		echo "cru:"
		cru l 2>/dev/null | grep -F "$CRU_ID" || echo "(none)"
	elif [ -f "$DATA_DIR/.update-cron" ]; then
		echo "marker=$(cat "$DATA_DIR/.update-cron")"
	else
		echo "cru=(unavailable)"
	fi
}

case "${1:-}" in
run)
	cmd_run
	;;
install-cru | install)
	install_cru
	;;
remove-cru | remove)
	remove_cru
	echo "schedule-update: job removed"
	;;
status)
	cmd_status
	;;
write-conf)
	shift
	conf_set_many "$@"
	install_cru
	echo "schedule-update: conf written"
	;;
*)
	echo "Usage: $0 run|install-cru|remove-cru|status|write-conf [k=v…]" >&2
	exit 2
	;;
esac
