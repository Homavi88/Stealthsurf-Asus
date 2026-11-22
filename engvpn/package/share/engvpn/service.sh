#!/bin/sh
# EngVPN Merlin service — start/stop/restart/check for the panel daemon.
# Lives in <prefix>/share/engvpn; daemon in <prefix>/sbin/engvpnd.
set -u

SHARE=$(cd "${0%/*}" 2>/dev/null && pwd -P) || exit 1
PREFIX=${SHARE%/share/engvpn}
DAEMON=$PREFIX/sbin/engvpnd
DATA_DIR=$PREFIX/data
VOLATILE_DIR=/tmp/engvpn
PIDFILE=/tmp/engvpn-panel.pid
SUPERVISOR_PIDFILE=/tmp/engvpn-supervisor.pid
LOG=$VOLATILE_DIR/engvpnd.log
START_LOCK=$DATA_DIR/.service.lock
SHARED_LOCK_DIR=${ENGVPN_LOCK_DIR:-/jffs/addons}
if [ "${ENGVPN_SMOKE:-}" = 1 ] && [ -z "${ENGVPN_LOCK_DIR:-}" ]; then
	SHARED_LOCK_DIR=/tmp/engvpn-smoke-lock
fi
SHARED_LOCK=$SHARED_LOCK_DIR/.engvpn-service.lock
PORT=${ENGVPN_PORT:-8790}
PATH="/opt/bin:/opt/sbin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
export PATH
export ENGVPN_PORT="$PORT"
export ENGVPN_PIDFILE="$PIDFILE"
export ENGVPN_DATA_DIR="$DATA_DIR"
export ENGVPN_SMOKE="${ENGVPN_SMOKE:-}"
export ENGVPN_LOCK_DIR="$SHARED_LOCK_DIR"

ACTION=${1:-}

read_pid() {
	[ -f "$1" ] || return 1
	read -r pid <"$1" 2>/dev/null || return 1
	case $pid in
	'' | *[!0-9]*) return 1 ;;
	esac
	echo "$pid"
}

alive() {
	[ -n "$1" ] && [ -d "/proc/$1" ]
}

own_panel() {
	alive "$1" || return 1
	cmd=$(tr '\000' ' ' <"/proc/$1/cmdline" 2>/dev/null) || return 1
	case "$cmd" in
	*"$PREFIX"*run.mjs* | *"$PREFIX"*engvpnd*serve*) return 0 ;;
	esac
	# Smoke / local: cwd under prefix
	cwd=$(readlink "/proc/$1/cwd" 2>/dev/null || true)
	case "$cwd" in
	"$PREFIX" | "$PREFIX"/* | "$SHARE"/runtime | "$SHARE"/runtime/*) return 0 ;;
	esac
	return 1
}

daemon_pid() {
	pid=$(read_pid "$PIDFILE") && own_panel "$pid" && {
		echo "$pid"
		return 0
	}
	for entry in /proc/[0-9]*; do
		pid=${entry#/proc/}
		own_panel "$pid" && {
			echo "$pid"
			return 0
		}
	done
	return 1
}

supervisor_pid() {
	pid=$(read_pid "$SUPERVISOR_PIDFILE") && alive "$pid" && echo "$pid"
}

running() {
	supervisor_pid >/dev/null || daemon_pid >/dev/null
}

ensure_firewall() {
	[ -d /jffs/scripts ] || return 0
	if type iptables >/dev/null 2>&1; then
		iptables -C INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null ||
			iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || true
	fi
}

open_panel_port_hook() {
	[ -d /jffs/scripts ] || return 0
	fs=/jffs/scripts/firewall-start
	touch "$fs" 2>/dev/null || return 0
	chmod +x "$fs" 2>/dev/null || true
	mark="# EngVPN panel"
	grep -qF "$mark" "$fs" 2>/dev/null && return 0
	printf '\niptables -I INPUT -p tcp --dport %s -j ACCEPT 2>/dev/null %s\n' "$PORT" "$mark" >>"$fs"
}

take_start_lock() {
	mkdir -p "$DATA_DIR" 2>/dev/null
	chmod 700 "$DATA_DIR" 2>/dev/null || true
	mkdir -p "$SHARED_LOCK_DIR" 2>/dev/null || true
	if type flock >/dev/null 2>&1; then
		# Best-effort locks; failure must not abort start (esp. smoke hosts).
		{ exec 6>>"$SHARED_LOCK" && flock -n 6; } 2>/dev/null || true
		{ exec 8>>"$START_LOCK" && flock -n 8; } 2>/dev/null || true
	fi
}

do_start() {
	mkdir -p "$VOLATILE_DIR" "$DATA_DIR"
	chmod 700 "$DATA_DIR" 2>/dev/null || true
	: >>"$LOG" 2>/dev/null || true
	take_start_lock
	if running; then
		echo "EngVPN already running"
		return 0
	fi
	[ -x "$DAEMON" ] || {
		echo "EngVPN: missing $DAEMON" >&2
		return 1
	}
	ensure_firewall
	open_panel_port_hook
	# Supervisor: restart panel if it exits unexpectedly.
	(
		trap '' HUP
		mkdir -p "$VOLATILE_DIR" 2>/dev/null || true
		printf '%s\n' "$$" >"$SUPERVISOR_PIDFILE"
		while :; do
			"$DAEMON" serve --data-dir "$DATA_DIR" >>"$LOG" 2>&1 &
			child=$!
			printf '%s\n' "$child" >"$PIDFILE"
			wait "$child"
			code=$?
			rm -f "$PIDFILE"
			# Clean stop requested
			[ -f "$DATA_DIR/.stop-requested" ] && rm -f "$DATA_DIR/.stop-requested" && break
			mkdir -p "$VOLATILE_DIR" 2>/dev/null || true
			echo "EngVPN panel exited ($code); restarting in 3s" >>"$LOG" 2>/dev/null || true
			sleep 3
		done
		rm -f "$SUPERVISOR_PIDFILE"
	) &
	# Wait briefly for listen
	i=0
	while [ "$i" -lt 15 ]; do
		running && break
		sleep 1
		i=$((i + 1))
	done
	if running; then
		echo "EngVPN started (port $PORT)"
		return 0
	fi
	echo "EngVPN failed to start — see $LOG" >&2
	return 1
}

do_stop() {
	mkdir -p "$DATA_DIR" 2>/dev/null
	touch "$DATA_DIR/.stop-requested"
	sup=$(supervisor_pid || true)
	pid=$(daemon_pid || true)
	[ -n "$sup" ] && kill "$sup" 2>/dev/null || true
	[ -n "$pid" ] && kill "$pid" 2>/dev/null || true
	i=0
	while [ "$i" -lt 20 ]; do
		running || break
		sleep 1
		i=$((i + 1))
	done
	sup=$(supervisor_pid || true)
	pid=$(daemon_pid || true)
	[ -n "$sup" ] && kill -9 "$sup" 2>/dev/null || true
	[ -n "$pid" ] && kill -9 "$pid" 2>/dev/null || true
	rm -f "$PIDFILE" "$SUPERVISOR_PIDFILE" "$DATA_DIR/.stop-requested"
	echo "EngVPN stopped"
}

do_check() {
	if running; then
		echo "running"
		return 0
	fi
	echo "stopped"
	return 1
}

case "$ACTION" in
start) do_start ;;
stop | stop-held) do_stop ;;
restart)
	do_stop
	do_start
	;;
check | status) do_check ;;
kill | kill-strays) do_stop ;;
*)
	echo "Usage: $0 start|stop|restart|check" >&2
	exit 2
	;;
esac
