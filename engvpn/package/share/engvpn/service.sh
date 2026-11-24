#!/bin/sh
# EngVPN Merlin service — start/stop/restart/check for the panel daemon.
#
# Single-instance (Merlin CPU / restart storm):
#   1. ONE supervisor per PREFIX — flock on $DATA_DIR/.supervisor.lock for the
#      supervisor's entire lifetime (not released when this script exits).
#   2. ONE node …/run.mjs — engvpnd serve holds $DATA_DIR/.panel.lock (exit 75).
#   3. Per-prefix pid/log under /tmp/engvpn-<hash>/ (never share global pidfiles).
#   4. Supervisor EXITS if engvpnd is missing (exit 127) or DATA_DIR gone —
#      prevents orphan loops after rm -rf / uninstall / USB unmount.
set -u

SHARE=$(cd "${0%/*}" 2>/dev/null && pwd -P) || exit 1
PREFIX=${SHARE%/share/engvpn}
DAEMON=$PREFIX/sbin/engvpnd
DATA_DIR=$PREFIX/data
# Unique volatile dir per PREFIX (BusyBox md5sum) — avoids cross-smoke / cross-install storms
PREFIX_HASH=$(printf '%s' "$PREFIX" | md5sum 2>/dev/null | awk '{print substr($1,1,12)}')
[ -n "$PREFIX_HASH" ] || PREFIX_HASH=default
VOLATILE_DIR=/tmp/engvpn-$PREFIX_HASH
PIDFILE=$VOLATILE_DIR/panel.pid
SUPERVISOR_PIDFILE=$VOLATILE_DIR/supervisor.pid
LOG=$VOLATILE_DIR/engvpnd.log
SUPERVISOR_LOCK=$DATA_DIR/.supervisor.lock
PANEL_LOCK=$DATA_DIR/.panel.lock
PORT=${ENGVPN_PORT:-8790}
PATH="/opt/bin:/opt/sbin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
export PATH
export ENGVPN_PORT="$PORT"
export ENGVPN_PIDFILE="$PIDFILE"
export ENGVPN_DATA_DIR="$DATA_DIR"
export ENGVPN_SMOKE="${ENGVPN_SMOKE:-}"
if [ -z "${ENGVPN_OPEN_PANEL:-}" ] && [ -f "$DATA_DIR/open-panel" ]; then
	export ENGVPN_OPEN_PANEL=1
fi
[ -n "${ENGVPN_SS_API:-}" ] && export ENGVPN_SS_API

ACTION=${1:-}
DUP_EXIT=75
CHILDREN_FILE=$VOLATILE_DIR/supervisor.children

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

# BusyBox ash prints "service.sh: line N: can't open /proc/PID/cmdline" on failed
# <redir (2>/dev/null on the child does NOT silence the shell). Race after kill.
# Always: test -r, then cat (no shell <redir), stderr discarded.
read_cmdline() {
	[ -n "${1:-}" ] || return 1
	[ -d "/proc/$1" ] || return 1
	[ -r "/proc/$1/cmdline" ] || return 1
	_cmd=
	# Brace + 2>/dev/null: swallow late races between -r and cat
	{ _cmd=$(cat "/proc/$1/cmdline" 2>/dev/null | tr '\000' ' '); } 2>/dev/null || return 1
	[ -n "$_cmd" ] || return 1
	printf '%s\n' "$_cmd"
}

read_environ() {
	[ -n "${1:-}" ] || return 1
	[ -d "/proc/$1" ] || return 1
	[ -r "/proc/$1/environ" ] || return 1
	_env=
	{ _env=$(cat "/proc/$1/environ" 2>/dev/null | tr '\000' '\n'); } 2>/dev/null || return 1
	printf '%s\n' "$_env"
}

own_panel() {
	alive "$1" || return 1
	cmd=$(read_cmdline "$1") || return 1
	case "$cmd" in
	*"$PREFIX"*run.mjs*) return 0 ;;
	*"$PREFIX"*engvpnd*serve*) return 0 ;;
	*"$SHARE"/runtime/run.mjs*) return 0 ;;
	esac
	cwd=$(readlink "/proc/$1/cwd" 2>/dev/null || true)
	case "$cwd" in
	"$SHARE"/runtime | "$SHARE"/runtime/*) return 0 ;;
	esac
	return 1
}

own_service_script() {
	alive "$1" || return 1
	[ "$1" = "$$" ] && return 1
	cmd=$(read_cmdline "$1") || return 1
	case "$cmd" in
	*"$SHARE/service.sh"* | *"$PREFIX/share/engvpn/service.sh"*) return 0 ;;
	esac
	return 1
}

# sleep / watchdog left after supervisor SIGKILL — reparented to init (PPID=1).
# Match via EngVPN env exported by this script (survives across reparent).
is_engvpn_helper() {
	alive "$1" || return 1
	[ "$1" = "$$" ] && return 1
	cmd=$(read_cmdline "$1") || return 1
	case "$cmd" in
	sleep\ * | */sleep\ * | sleep) ;;
	*"$DAEMON"*watchdog* | *engvpnd\ watchdog*) ;;
	*) return 1 ;;
	esac
	envtxt=$(read_environ "$1") || return 1
	case "$envtxt" in
	*"ENGVPN_DATA_DIR=$DATA_DIR"* | *"ENGVPN_PIDFILE=$PIDFILE"*) return 0 ;;
	esac
	return 1
}

panel_count() {
	n=0
	for entry in /proc/[0-9]*; do
		pid=${entry#/proc/}
		own_panel "$pid" || continue
		n=$((n + 1))
	done
	echo "$n"
}

supervisor_count() {
	n=0
	for entry in /proc/[0-9]*; do
		pid=${entry#/proc/}
		own_service_script "$pid" || continue
		n=$((n + 1))
	done
	echo "$n"
}

daemon_pid() {
	pid=$(read_pid "$PIDFILE") && own_panel "$pid" && {
		echo "$pid"
		return 0
	}
	best=
	for entry in /proc/[0-9]*; do
		pid=${entry#/proc/}
		own_panel "$pid" || continue
		case $best in
		'') best=$pid ;;
		*) [ "$pid" -lt "$best" ] 2>/dev/null && best=$pid ;;
		esac
	done
	[ -n "$best" ] && echo "$best" && return 0
	return 1
}

supervisor_pid() {
	pid=$(read_pid "$SUPERVISOR_PIDFILE") && alive "$pid" && echo "$pid"
}

# Kill orphan supervisors whose package path no longer exists (smoke cleanup / USB yank).
kill_dead_prefix_supervisors() {
	for entry in /proc/[0-9]*; do
		p=${entry#/proc/}
		[ "$p" = "$$" ] && continue
		cmd=$(read_cmdline "$p") || continue
		case "$cmd" in
		*/share/engvpn/service.sh*)
			case "$cmd" in
			*"$SHARE/service.sh"*) continue ;;
			esac
			spath=$(printf '%s\n' "$cmd" | tr ' ' '\n' | grep '/share/engvpn/service.sh$' | head -n1)
			[ -z "$spath" ] && spath=$(printf '%s\n' "$cmd" | tr ' ' '\n' | grep '/share/engvpn/service.sh' | head -n1)
			if [ -n "$spath" ] && [ ! -x "$spath" ]; then
				kill_children_of "$p"
				kill "$p" 2>/dev/null || true
			fi
			;;
		esac
	done
}

# Kill direct children of a supervisor (sleep/watchdog inherit flock fd 8 unless closed).
kill_children_of() {
	parent=$1
	[ -n "$parent" ] && [ "$parent" != "$$" ] || return 0
	for entry in /proc/[0-9]*; do
		p=${entry#/proc/}
		[ "$p" = "$$" ] && continue
		[ -r "$entry/status" ] || continue
		ppid=
		{ ppid=$(awk '/^PPid:/{print $2; exit}' "$entry/status"); } 2>/dev/null || continue
		[ "$ppid" = "$parent" ] || continue
		kill "$p" 2>/dev/null || true
	done
}

# Reap hung sleep/watchdog helpers for this PREFIX (incl. PPID=1 orphans).
kill_orphan_helpers() {
	# PIDs recorded by supervisor_sleep before reparent
	if [ -f "$CHILDREN_FILE" ]; then
		while read -r cp || [ -n "${cp:-}" ]; do
			case $cp in
			'' | *[!0-9]*) continue ;;
			esac
			[ "$cp" = "$$" ] && continue
			kill "$cp" 2>/dev/null || true
		done <"$CHILDREN_FILE"
	fi
	for entry in /proc/[0-9]*; do
		p=${entry#/proc/}
		is_engvpn_helper "$p" || continue
		kill "$p" 2>/dev/null || true
	done
}

# Soft cleanup before start: helpers + storm of sh/service.sh + extra run.mjs.
reap_orphans_on_start() {
	mkdir -p "$VOLATILE_DIR" "$DATA_DIR" 2>/dev/null || true
	kill_dead_prefix_supervisors
	kill_orphan_helpers

	n=$(panel_count)
	if [ "$n" -gt 1 ]; then
		echo "EngVPN: start cleanup — culling $n panels" >>"$LOG" 2>/dev/null || true
		cull_extra_panels
	fi

	n_sup=$(supervisor_count)
	if [ "$n_sup" -gt 1 ]; then
		echo "EngVPN: start cleanup — reaping $n_sup supervisors" >>"$LOG" 2>/dev/null || true
		for entry in /proc/[0-9]*; do
			p=${entry#/proc/}
			[ "$p" = "$$" ] && continue
			own_service_script "$p" || continue
			kill_children_of "$p"
			kill "$p" 2>/dev/null || true
		done
		kill_orphan_helpers
		rm -f "$SUPERVISOR_PIDFILE" "$CHILDREN_FILE" 2>/dev/null || true
		rm -rf "$SUPERVISOR_LOCK.d" 2>/dev/null || true
	fi
}

# Tracked sleep so EXIT trap / kill-strays can reap after SIGKILL reparent.
supervisor_sleep() {
	_secs=$1
	sleep "$_secs" 8>&- &
	_sp=$!
	printf '%s\n' "$_sp" >>"$CHILDREN_FILE" 2>/dev/null || true
	wait "$_sp" 2>/dev/null || true
}

kill_strays() {
	mkdir -p "$VOLATILE_DIR" "$DATA_DIR" 2>/dev/null || true
	touch "$DATA_DIR/.stop-requested" 2>/dev/null || true

	kill_dead_prefix_supervisors
	kill_orphan_helpers

	sup=$(read_pid "$SUPERVISOR_PIDFILE" 2>/dev/null || true)
	# Reap children first so an orphan sleep cannot keep .supervisor.lock
	[ -n "${sup:-}" ] && kill_children_of "$sup"
	[ -n "${sup:-}" ] && [ "$sup" != "$$" ] && kill "$sup" 2>/dev/null || true
	pid=$(read_pid "$PIDFILE" 2>/dev/null || true)
	[ -n "${pid:-}" ] && kill_children_of "$pid"
	[ -n "${pid:-}" ] && kill "$pid" 2>/dev/null || true

	for entry in /proc/[0-9]*; do
		p=${entry#/proc/}
		[ "$p" = "$$" ] && continue
		if own_panel "$p" || own_service_script "$p" || is_engvpn_helper "$p"; then
			kill_children_of "$p"
			kill "$p" 2>/dev/null || true
		fi
	done

	i=0
	while [ "$i" -lt 8 ]; do
		left=0
		for entry in /proc/[0-9]*; do
			p=${entry#/proc/}
			[ "$p" = "$$" ] && continue
			if own_panel "$p" || own_service_script "$p" || is_engvpn_helper "$p"; then
				left=1
				break
			fi
		done
		[ "$left" = 0 ] && break
		kill_orphan_helpers
		sleep 1
		i=$((i + 1))
	done

	for entry in /proc/[0-9]*; do
		p=${entry#/proc/}
		[ "$p" = "$$" ] && continue
		if own_panel "$p" || own_service_script "$p" || is_engvpn_helper "$p"; then
			kill_children_of "$p"
			kill -9 "$p" 2>/dev/null || true
		fi
	done
	kill_orphan_helpers
	[ -n "${sup:-}" ] && kill_children_of "$sup"
	[ -n "${sup:-}" ] && [ "$sup" != "$$" ] && kill -9 "$sup" 2>/dev/null || true

	rm -f "$PIDFILE" "$SUPERVISOR_PIDFILE" "$CHILDREN_FILE" "$DATA_DIR/.stop-requested"
	rm -rf "$PANEL_LOCK.d" "$SUPERVISOR_LOCK.d" 2>/dev/null || true

	# Wait until .supervisor.lock is free (orphan sleep used to hold it after kill)
	if type flock >/dev/null 2>&1; then
		w=0
		while [ "$w" -lt 6 ]; do
			if (
				flock -n 9 || exit 1
				exit 0
			) 9>>"$SUPERVISOR_LOCK" 2>/dev/null; then
				break
			fi
			kill_orphan_helpers
			sleep 1
			w=$((w + 1))
		done
	fi
}

cull_extra_panels() {
	keep=$(daemon_pid || true)
	[ -n "$keep" ] || return 0
	for entry in /proc/[0-9]*; do
		p=${entry#/proc/}
		[ "$p" = "$keep" ] && continue
		own_panel "$p" || continue
		kill "$p" 2>/dev/null || true
	done
	printf '%s\n' "$keep" >"$PIDFILE" 2>/dev/null || true
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

do_start() {
	mkdir -p "$VOLATILE_DIR" "$DATA_DIR"
	chmod 700 "$DATA_DIR" 2>/dev/null || true
	: >>"$LOG" 2>/dev/null || true
	: >>"$SUPERVISOR_LOCK" 2>/dev/null || true
	rm -f "$DATA_DIR/.stop-requested" 2>/dev/null || true

	# Auto-cleanup: hung sleeps, multi sh/service.sh, multi run.mjs
	reap_orphans_on_start

	[ -x "$DAEMON" ] || {
		echo "EngVPN: missing $DAEMON" >&2
		return 1
	}
	ensure_firewall
	open_panel_port_hook

	if [ -f "$DATA_DIR/transparent.conf" ] && [ -x "$SHARE/transparent.sh" ]; then
		mode=$(awk -F= '$1=="mode"{print $2}' "$DATA_DIR/transparent.conf" 2>/dev/null || true)
		if [ -n "$mode" ] && [ "$mode" != off ]; then
			sh "$SHARE/transparent.sh" apply >>"$LOG" 2>&1 || true
		fi
	fi

	if type flock >/dev/null 2>&1; then
		(
			trap '' HUP
			trap 'kill_children_of $$; kill_orphan_helpers; rm -f "$SUPERVISOR_PIDFILE" "$CHILDREN_FILE"' EXIT
			flock -n 8 || {
				echo "EngVPN supervisor: lock busy — not starting another" >>"$LOG" 2>/dev/null || true
				exit 0
			}
			: >"$CHILDREN_FILE" 2>/dev/null || true
			printf '%s\n' "$$" >"$SUPERVISOR_PIDFILE"
			# Line-buffer log lines so restart diagnostics are not stuck in stdio
			echo "EngVPN supervisor $$ holding $SUPERVISOR_LOCK prefix=$PREFIX" >>"$LOG" 2>/dev/null || true
			ticks=0
			while :; do
				[ -f "$DATA_DIR/.stop-requested" ] && break
				# Package yanked / smoke cleaned PREFIX — stop looping forever
				if [ ! -x "$DAEMON" ] || [ ! -d "$DATA_DIR" ]; then
					echo "EngVPN supervisor: daemon/data gone — exit" >>"$LOG" 2>/dev/null || true
					break
				fi

				n=$(panel_count)
				if [ "$n" -gt 1 ]; then
					echo "EngVPN supervisor: cull extras ($n)" >>"$LOG" 2>/dev/null || true
					cull_extra_panels
					n=$(panel_count)
				fi
				# Periodic helper reap (orphaned sleeps from prior storms)
				kill_orphan_helpers

				if [ "$n" -ge 1 ]; then
					pid=$(daemon_pid || true)
					[ -n "${pid:-}" ] && printf '%s\n' "$pid" >"$PIDFILE"
					# Tracked sleep — EXIT trap / kill-strays can reap after SIGKILL
					supervisor_sleep 5
					ticks=$((ticks + 5))
					if [ "$ticks" -ge 60 ]; then
						ticks=0
						"$DAEMON" watchdog 8>&- >>"$LOG" 2>&1 || true
					fi
					continue
				fi

				# 8>&- : do not inherit supervisor flock into engvpnd/node
				"$DAEMON" serve --data-dir "$DATA_DIR" 8>&- >>"$LOG" 2>&1 &
				child=$!
				printf '%s\n' "$child" >"$PIDFILE"
				while kill -0 "$child" 2>/dev/null; do
					[ -f "$DATA_DIR/.stop-requested" ] && break
					[ -x "$DAEMON" ] || break
					for entry in /proc/[0-9]*; do
						p=${entry#/proc/}
						[ "$p" = "$child" ] && continue
						own_panel "$p" || continue
						echo "EngVPN supervisor: killing stray panel $p" >>"$LOG" 2>/dev/null || true
						kill "$p" 2>/dev/null || true
					done
					supervisor_sleep 5
					ticks=$((ticks + 5))
					if [ "$ticks" -ge 60 ]; then
						ticks=0
						"$DAEMON" watchdog 8>&- >>"$LOG" 2>&1 || true
					fi
				done
				wait "$child" 2>/dev/null
				code=$?
				rm -f "$PIDFILE"
				[ -f "$DATA_DIR/.stop-requested" ] && break
				if [ ! -x "$DAEMON" ] || [ ! -d "$DATA_DIR" ]; then
					echo "EngVPN supervisor: daemon/data gone after child — exit" >>"$LOG" 2>/dev/null || true
					break
				fi
				# 127 = command not found; 75 = duplicate lock / EADDRINUSE
				if [ "$code" = 127 ]; then
					echo "EngVPN supervisor: engvpnd missing (127) — exit" >>"$LOG" 2>/dev/null || true
					break
				fi
				if [ "$code" = "$DUP_EXIT" ] || [ "$code" = 75 ]; then
					echo "EngVPN panel duplicate (exit $code); back off 15s" >>"$LOG" 2>/dev/null || true
					supervisor_sleep 15
					continue
				fi
				echo "EngVPN panel exited ($code); restart in 5s" >>"$LOG" 2>/dev/null || true
				supervisor_sleep 5
			done
			rm -f "$SUPERVISOR_PIDFILE" "$CHILDREN_FILE"
		) 8>>"$SUPERVISOR_LOCK" >>"$LOG" 2>&1 &
	else
		if ! mkdir "$SUPERVISOR_LOCK.d" 2>/dev/null; then
			echo "EngVPN already running"
			[ "$(panel_count)" -gt 1 ] && cull_extra_panels
			kill_orphan_helpers
			return 0
		fi
		(
			trap '' HUP
			trap 'kill_children_of $$; kill_orphan_helpers; rm -f "$SUPERVISOR_PIDFILE" "$CHILDREN_FILE"; rmdir "$SUPERVISOR_LOCK.d" 2>/dev/null || true' EXIT
			: >"$CHILDREN_FILE" 2>/dev/null || true
			printf '%s\n' "$$" >"$SUPERVISOR_PIDFILE"
			while :; do
				[ -f "$DATA_DIR/.stop-requested" ] && break
				[ -x "$DAEMON" ] && [ -d "$DATA_DIR" ] || break
				n=$(panel_count)
				[ "$n" -gt 1 ] && cull_extra_panels
				kill_orphan_helpers
				n=$(panel_count)
				if [ "$n" -ge 1 ]; then
					pid=$(daemon_pid || true)
					[ -n "${pid:-}" ] && printf '%s\n' "$pid" >"$PIDFILE"
					supervisor_sleep 5
					continue
				fi
				"$DAEMON" serve --data-dir "$DATA_DIR" >>"$LOG" 2>&1 &
				child=$!
				printf '%s\n' "$child" >"$PIDFILE"
				while kill -0 "$child" 2>/dev/null; do
					[ -f "$DATA_DIR/.stop-requested" ] && break
					[ -x "$DAEMON" ] || break
					supervisor_sleep 5
				done
				wait "$child" 2>/dev/null
				code=$?
				rm -f "$PIDFILE"
				[ -f "$DATA_DIR/.stop-requested" ] && break
				[ ! -x "$DAEMON" ] && break
				[ "$code" = 127 ] && break
				[ "$code" = 75 ] && supervisor_sleep 15 && continue
				supervisor_sleep 5
			done
			rm -f "$SUPERVISOR_PIDFILE" "$CHILDREN_FILE"
			rmdir "$SUPERVISOR_LOCK.d" 2>/dev/null || true
		) >>"$LOG" 2>&1 &
	fi

	i=0
	while [ "$i" -lt 30 ]; do
		n=$(panel_count)
		[ "$n" -ge 1 ] && break
		# Supervisor holding lock but panel still booting
		sup=$(supervisor_pid || true)
		sleep 1
		i=$((i + 1))
	done
	n=$(panel_count)
	if [ "$n" -ge 1 ]; then
		[ "$n" -gt 1 ] && cull_extra_panels
		echo "EngVPN started (port $PORT)"
		return 0
	fi
	# Another start won the flock / supervisor still booting
	if supervisor_pid >/dev/null || [ -d "$SUPERVISOR_LOCK.d" ]; then
		echo "EngVPN already running"
		return 0
	fi
	if type flock >/dev/null 2>&1; then
		if ! flock -n 9 9>>"$SUPERVISOR_LOCK" 2>/dev/null; then
			echo "EngVPN already running"
			return 0
		fi
		# Acquired unexpectedly with no panel — release via subshell end
		flock -u 9 2>/dev/null || true
	fi
	echo "EngVPN failed to start — see $LOG" >&2
	return 1
}

do_stop() {
	mkdir -p "$DATA_DIR" "$VOLATILE_DIR" 2>/dev/null || true
	# Quiet: /proc races during reap must not spam the console
	kill_strays 2>/dev/null || true
	rm -f "$PANEL_LOCK" 2>/dev/null || true
	echo "EngVPN stopped"
}

do_check() {
	n=$(panel_count)
	if [ "$n" -ge 1 ]; then
		if [ "$n" -gt 1 ]; then
			echo "running (WARNING: $n panels)"
			return 0
		fi
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
	sleep 1
	do_start
	;;
check | status) do_check ;;
kill | kill-strays)
	# Quiet on purpose — BusyBox ash /proc races during reap
	kill_strays 2>/dev/null || true
	kill_dead_prefix_supervisors 2>/dev/null || true
	echo "EngVPN strays killed"
	;;
*)
	echo "Usage: $0 start|stop|restart|check|kill-strays" >&2
	exit 2
	;;
esac
