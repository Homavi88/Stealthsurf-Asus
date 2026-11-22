#!/bin/sh
# EngVPN netfilter helper — panel port + transparent rule replay after Merlin rebuilds tables.
#
# State file ($DATA/netfilter/rules) written by transparent.sh:
#   pid <n>
#   boot <id>
#   hold <unix>          optional: keep kill-switch until deadline while updating
#   iptables <path>
#   4 nat chain ENGVPN
#   4 nat hook PREROUTING -j ENGVPN
#   …
set -u

SHARE=$(cd "${0%/*}" 2>/dev/null && pwd) || exit 0
PREFIX=${SHARE%/share/engvpn}
DATA_DIR=${ENGVPN_DATA_DIR:-$PREFIX/data}
STATE=${ENGVPN_NETFILTER_STATE:-$DATA_DIR/netfilter/rules}
PORT=${ENGVPN_PORT:-8790}
TRANSPARENT=$SHARE/transparent.sh
LOCK=$DATA_DIR/.replay.lock
PATH=/opt/bin:/opt/sbin:/sbin:/bin:/usr/sbin:/usr/bin
export PATH

ipt_try() {
	if iptables -w 2 -h >/dev/null 2>&1; then
		iptables -w 2 "$@"
	else
		iptables "$@"
	fi
}

ensure_panel_port() {
	type iptables >/dev/null 2>&1 || return 0
	ipt_try -C INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null ||
		ipt_try -I INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || true
}

daemon_alive() {
	[ -r "$STATE" ] || return 1
	pid=$(awk '$1 == "pid" { print $2; exit }' "$STATE")
	[ -n "$pid" ] && [ -d "/proc/$pid" ] || return 1
	# Accept panel, engvpnd, or supervisor
	cmd=$(tr '\000' ' ' <"/proc/$pid/cmdline" 2>/dev/null || true)
	case "$cmd" in
	*engvpn* | *engvpnd* | *run.mjs*) return 0 ;;
	esac
	# hold window during update
	hold=$(awk '$1 == "hold" { print $2; exit }' "$STATE")
	case "$hold" in
	'' | *[!0-9]*) return 1 ;;
	esac
	now=$(date +%s)
	[ "$now" -le "$hold" ]
}

take_lock() {
	[ -n "${ENGVPN_REPLAY_LOCKED:-}" ] && return 0
	mkdir -p "$DATA_DIR" 2>/dev/null || true
	if type flock >/dev/null 2>&1; then
		if (: >>"$LOCK") 2>/dev/null; then
			exec 7>>"$LOCK"
			flock 7
		elif [ -f "$LOCK" ] && (: <"$LOCK") 2>/dev/null; then
			exec 7<"$LOCK"
			flock 7
		fi
	fi
}

# Prefer re-applying via transparent.sh (idempotent) when daemon still owns the state.
replay() {
	ensure_panel_port
	[ -r "$STATE" ] || {
		echo none
		return 0
	}
	take_lock
	if ! daemon_alive; then
		echo none
		return 0
	fi
	if [ -x "$TRANSPARENT" ]; then
		export ENGVPN_DATA_DIR="$DATA_DIR"
		# Re-read conf and rebuild chains after firmware flush
		if sh "$TRANSPARENT" apply >/dev/null 2>&1; then
			echo replayed
			return 0
		fi
	fi
	# Fallback: recreate empty chains + hooks from state lines
	tool=$(awk '$1 == "iptables" { print $2; exit }' "$STATE")
	[ -n "$tool" ] && [ -x "$tool" ] || tool=$(command -v iptables 2>/dev/null || true)
	[ -n "$tool" ] || {
		echo none
		return 0
	}
	replayed=
	set -f
	while read -r family table verb chain rest; do
		[ "$family" = 4 ] || continue
		case "$verb" in
		chain)
			"$tool" -t "$table" -N "$chain" 2>/dev/null || true
			replayed=1
			;;
		hook)
			"$tool" -t "$table" -C "$chain" $rest >/dev/null 2>&1 ||
				"$tool" -t "$table" -I "$chain" $rest 2>/dev/null || true
			replayed=1
			;;
		esac
	done <"$STATE"
	set +f
	[ -n "$replayed" ] && echo replayed || echo none
}

set_hold() {
	# $1 = seconds to hold kill-switch / rules during upgrade
	secs=${1:-90}
	mkdir -p "$(dirname "$STATE")"
	[ -f "$STATE" ] || {
		echo "no state" >&2
		return 1
	}
	until=$(date +%s)
	until=$((until + secs))
	grep -v '^hold ' "$STATE" >"$STATE.new" 2>/dev/null || cp "$STATE" "$STATE.new"
	echo "hold $until" >>"$STATE.new"
	mv -f "$STATE.new" "$STATE"
	echo "hold_until=$until"
}

case "${1:-ensure-port}" in
ensure-port) ensure_panel_port ;;
replay) replay ;;
set-hold) set_hold "${2:-90}" ;;
*)
	echo "Usage: $0 ensure-port|replay|set-hold [seconds]" >&2
	exit 2
	;;
esac
