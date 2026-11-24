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

# Node panel only (run.mjs). engvpnd serve parent holds flock and is tracked separately.
own_panel() {
	alive "$1" || return 1
	cmd=$(read_cmdline "$1") || return 1
	case "$cmd" in
	*"$PREFIX"*run.mjs* | *"$SHARE"/runtime/run.mjs*) return 0 ;;
	*engvpn/share/engvpn/runtime/run.mjs*)
		# Broad match: any EngVPN install path (symlink / old PREFIX)
		case "$cmd" in
		*"$PREFIX"* | *"$SHARE"*) return 0 ;;
		esac
		;;
	esac
	cwd=$(readlink "/proc/$1/cwd" 2>/dev/null || true)
	case "$cwd" in
	"$SHARE"/runtime | "$SHARE"/runtime/*) return 0 ;;
	esac
	return 1
}

# Background supervisor shells (service.sh start/restart holding flock).
own_service_script() {
	alive "$1" || return 1
	[ "$1" = "$$" ] && return 1
	cmd=$(read_cmdline "$1") || return 1
	case "$cmd" in
	*"$SHARE/service.sh"* | *"$PREFIX/share/engvpn/service.sh"* | */engvpn/share/engvpn/service.sh*)
		case "$cmd" in
		*"$SHARE/service.sh"* | *"$PREFIX/share/engvpn/service.sh"*) return 0 ;;
		*"$PREFIX"*) return 0 ;;
		esac
		;;
	esac
	return 1
}

# engvpnd serve parent (holds panel flock while node runs) — kill with strays.
own_engvpnd_serve() {
	alive "$1" || return 1
	[ "$1" = "$$" ] && return 1
	cmd=$(read_cmdline "$1") || return 1
	case "$cmd" in
	*"$DAEMON"*serve* | *"$PREFIX/sbin/engvpnd"*serve* | *engvpnd\ serve*)
		case "$cmd" in
		*"$PREFIX"* | *"$DAEMON"*) return 0 ;;
		esac
		;;
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

# Brute-force path-scoped kill. Never pkill service.sh — that would SIGKILL $$ mid kill-strays.
brute_kill_prefix() {
	if command -v pkill >/dev/null 2>&1; then
		pkill -9 -f "$PREFIX/share/engvpn/runtime/run.mjs" 2>/dev/null || true
		pkill -9 -f "$PREFIX/sbin/engvpnd serve" 2>/dev/null || true
		pkill -9 -f "$SHARE/runtime/run.mjs" 2>/dev/null || true
	fi
	# /proc sweep (skips $$): panels, engvpnd serve parents, other service.sh, helpers
	for entry in /proc/[0-9]*; do
		p=${entry#/proc/}
		[ "$p" = "$$" ] && continue
		cmd=$(read_cmdline "$p") || continue
		case "$cmd" in
		*"$PREFIX"* | *"$SHARE"*)
			case "$cmd" in
			*run.mjs* | *service.sh* | *engvpnd*serve* | *engvpnd\ serve*)
				kill_children_of "$p"
				kill -9 "$p" 2>/dev/null || true
				;;
			esac
			;;
		esac
	done
}

# Lock held by a live supervisor? (flock or lockdir)
supervisor_lock_busy() {
	if [ -d "$SUPERVISOR_LOCK.d" ]; then
		return 0
	fi
	if type flock >/dev/null 2>&1; then
		if ! (
			flock -n 9 || exit 1
			exit 0
		) 9>>"$SUPERVISOR_LOCK" 2>/dev/null; then
			return 0
		fi
	fi
	return 1
}

# Pick one live supervisor to keep (pidfile first, else lowest PID). Excludes $$.
pick_keep_supervisor() {
	k=$(supervisor_pid 2>/dev/null || true)
	if [ -n "$k" ] && [ "$k" != "$$" ] && own_service_script "$k" 2>/dev/null; then
		echo "$k"
		return 0
	fi
	best=
	for entry in /proc/[0-9]*; do
		p=${entry#/proc/}
		[ "$p" = "$$" ] && continue
		own_service_script "$p" || continue
		case $best in
		'') best=$p ;;
		*) [ "$p" -lt "$best" ] 2>/dev/null && best=$p ;;
		esac
	done
	[ -n "$best" ] && echo "$best" && return 0
	return 1
}

# Kill extra service.sh, keep exactly one (keep_sup). Never touches $$.
cull_extra_supervisors() {
	keep_sup=$1
	for entry in /proc/[0-9]*; do
		p=${entry#/proc/}
		[ "$p" = "$$" ] && continue
		[ -n "$keep_sup" ] && [ "$p" = "$keep_sup" ] && continue
		own_service_script "$p" || continue
		kill_children_of "$p"
		kill -9 "$p" 2>/dev/null || true
	done
	kill_orphan_helpers
	[ -n "$keep_sup" ] && printf '%s\n' "$keep_sup" >"$SUPERVISOR_PIDFILE" 2>/dev/null || true
}

# Force-clear every supervisor for this PREFIX (no panel / stuck lock takeover).
# Only call when lock is free OR after a brief stuck-wait — never from a flock loser mid-race.
wipe_all_supervisors() {
	sup=$(read_pid "$SUPERVISOR_PIDFILE" 2>/dev/null || true)
	[ -n "${sup:-}" ] && [ "$sup" != "$$" ] && {
		kill_children_of "$sup"
		kill -9 "$sup" 2>/dev/null || true
	}
	for entry in /proc/[0-9]*; do
		p=${entry#/proc/}
		[ "$p" = "$$" ] && continue
		own_service_script "$p" || continue
		kill_children_of "$p"
		kill -9 "$p" 2>/dev/null || true
	done
	kill_orphan_helpers
	rm -f "$SUPERVISOR_PIDFILE" "$CHILDREN_FILE" 2>/dev/null || true
	rm -rf "$SUPERVISOR_LOCK.d" 2>/dev/null || true
	if type flock >/dev/null 2>&1; then
		(
			flock -n 9 || exit 0
			:
		) 9>>"$SUPERVISOR_LOCK" 2>/dev/null || true
	fi
}

# One-shot purge: orphan sleep/watchdog + extra service.sh when a healthy panel exists.
# SAFE for parallel start: never murders a racing lock-holder while panel is still booting.
# mode=force → wipe all supervisors (stuck lock / explicit takeover).
purge_orphans_oneshot() {
	_mode=${1:-}
	mkdir -p "$VOLATILE_DIR" "$DATA_DIR" 2>/dev/null || true
	kill_dead_prefix_supervisors
	kill_orphan_helpers

	n=$(panel_count)
	[ "$n" -gt 1 ] && cull_extra_panels
	n=$(panel_count)

	if [ "$n" -ge 1 ]; then
		keep_sup=$(pick_keep_supervisor 2>/dev/null || true)
		cull_extra_supervisors "$keep_sup"
		return 0
	fi

	# No panel yet.
	if [ "$_mode" = force ]; then
		wipe_all_supervisors
		return 0
	fi
	# Lock busy → another start owns spawn; only reap sleeps, do NOT kill service.sh.
	if supervisor_pid >/dev/null || supervisor_lock_busy; then
		kill_orphan_helpers
		return 0
	fi
	# Lock free, no panel — clear stale leftovers then caller spawns one.
	wipe_all_supervisors
}

# Hard single-instance on start.
# Returns 0 if panel already healthy (caller returns success), 1 if must spawn fresh.
# One-shot purge orphans; never wait 45s; never kill a racing winner mid-boot.
enforce_single_on_start() {
	mkdir -p "$VOLATILE_DIR" "$DATA_DIR" 2>/dev/null || true
	: >>"$SUPERVISOR_LOCK" 2>/dev/null || true
	: >>"$LOG" 2>/dev/null || true

	purge_orphans_oneshot

	n=$(panel_count)

	if [ "$n" -gt 1 ]; then
		echo "EngVPN: hard-enforce — $n panels → one-shot wipe" >>"$LOG" 2>/dev/null || true
		cull_extra_panels
		brute_kill_prefix
		purge_orphans_oneshot force
		n=$(panel_count)
		[ "$n" -le 1 ] || {
			kill_strays
			return 1
		}
	fi

	if [ "$n" -eq 1 ]; then
		echo "EngVPN: single panel present — keep" >>"$LOG" 2>/dev/null || true
		return 0
	fi

	# No panel: another start may own the lock — wait for its panel, do NOT murder it.
	if supervisor_lock_busy || supervisor_pid >/dev/null; then
		# Settle: winner may still be writing SUPERVISOR_PIDFILE after flock.
		_w=0
		while [ "$_w" -lt 2 ]; do
			supervisor_pid >/dev/null && break
			n=$(panel_count)
			[ "$n" -ge 1 ] && break
			supervisor_lock_busy || break
			sleep 1
			_w=$((_w + 1))
		done
		n=$(panel_count)
		if [ "$n" -ge 1 ]; then
			[ "$n" -gt 1 ] && cull_extra_panels
			purge_orphans_oneshot
			return 0
		fi
		if supervisor_pid >/dev/null; then
			# Live supervisor racing us — wait up to 8s for panel, then yield.
			echo "EngVPN: live supervisor — waiting for panel" >>"$LOG" 2>/dev/null || true
			_w=0
			while [ "$_w" -lt 8 ]; do
				n=$(panel_count)
				if [ "$n" -ge 1 ]; then
					[ "$n" -gt 1 ] && cull_extra_panels
					purge_orphans_oneshot
					return 0
				fi
				supervisor_pid >/dev/null || break
				sleep 1
				_w=$((_w + 1))
			done
			# Spawn path will flock-lose and wait_for_panel; no wipe of winner.
			echo "EngVPN: yield to live supervisor" >>"$LOG" 2>/dev/null || true
			return 1
		fi
		# Lock busy, no pidfile, no panel → orphan sleep/stale lock; one-shot takeover.
		if supervisor_lock_busy; then
			echo "EngVPN: orphan lock without supervisor — force purge and spawn one" >>"$LOG" 2>/dev/null || true
			purge_orphans_oneshot force
			return 1
		fi
	fi

	# Clean slate — spawn one supervisor
	return 1
}

# Tracked sleep so EXIT trap / kill-strays can reap after SIGKILL reparent.
supervisor_sleep() {
	_secs=$1
	sleep "$_secs" 8>&- &
	_sp=$!
	printf '%s\n' "$_sp" >>"$CHILDREN_FILE" 2>/dev/null || true
	wait "$_sp" 2>/dev/null || true
}

is_engvpn_process() {
	own_panel "$1" || own_service_script "$1" || own_engvpnd_serve "$1" || is_engvpn_helper "$1"
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
		if is_engvpn_process "$p"; then
			kill_children_of "$p"
			kill "$p" 2>/dev/null || true
		fi
	done

	# Path-scoped brute force — catches argv variants own_* missed
	brute_kill_prefix

	# Bounded reap (≤3s) — never hang install/update on «остановка лишних процессов».
	i=0
	while [ "$i" -lt 3 ]; do
		left=0
		for entry in /proc/[0-9]*; do
			p=${entry#/proc/}
			[ "$p" = "$$" ] && continue
			if is_engvpn_process "$p"; then
				left=1
				break
			fi
		done
		[ "$left" = 0 ] && break
		kill_orphan_helpers
		brute_kill_prefix
		sleep 1
		i=$((i + 1))
	done

	for entry in /proc/[0-9]*; do
		p=${entry#/proc/}
		[ "$p" = "$$" ] && continue
		if is_engvpn_process "$p"; then
			kill_children_of "$p"
			kill -9 "$p" 2>/dev/null || true
		fi
	done
	kill_orphan_helpers
	brute_kill_prefix
	[ -n "${sup:-}" ] && kill_children_of "$sup"
	[ -n "${sup:-}" ] && [ "$sup" != "$$" ] && kill -9 "$sup" 2>/dev/null || true

	rm -f "$PIDFILE" "$SUPERVISOR_PIDFILE" "$CHILDREN_FILE" "$DATA_DIR/.stop-requested"
	rm -rf "$PANEL_LOCK.d" "$SUPERVISOR_LOCK.d" 2>/dev/null || true

	# Best-effort free .supervisor.lock (orphan sleep used to hold it). Max 2s, flock -n only.
	if type flock >/dev/null 2>&1; then
		w=0
		while [ "$w" -lt 2 ]; do
			if (
				flock -n 9 || exit 1
				exit 0
			) 9>>"$SUPERVISOR_LOCK" 2>/dev/null; then
				break
			fi
			kill_orphan_helpers
			brute_kill_prefix
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

# Wait for panel with progress; ENGVPN_START_TIMEOUT seconds (default 45).
wait_for_panel() {
	_timeout=${ENGVPN_START_TIMEOUT:-45}
	case $_timeout in
	'' | *[!0-9]*) _timeout=45 ;;
	esac
	[ "$_timeout" -lt 5 ] && _timeout=5
	_i=0
	_quiet=${1:-}
	while [ "$_i" -lt "$_timeout" ]; do
		n=$(panel_count)
		if [ "$n" -ge 1 ]; then
			[ "$n" -gt 1 ] && cull_extra_panels
			[ -z "$_quiet" ] && [ "$_i" -gt 0 ] && printf '\n'
			return 0
		fi
		if [ -z "$_quiet" ]; then
			if [ "$_i" -eq 0 ]; then
				printf '  ожидание панели'
			fi
			printf '.'
			# every 10s print elapsed
			if [ "$((_i % 10))" -eq 9 ]; then
				printf ' %ss' "$((_i + 1))"
			fi
		fi
		sleep 1
		_i=$((_i + 1))
	done
	[ -z "$_quiet" ] && printf '\n'
	return 1
}

do_start() {
	# Disable monitor mode — otherwise ash prints «Terminated» when a
	# background sleep/helper from kill-strays/supervisor is reaped.
	set +m 2>/dev/null || true
	mkdir -p "$VOLATILE_DIR" "$DATA_DIR"
	chmod 700 "$DATA_DIR" 2>/dev/null || true
	: >>"$LOG" 2>/dev/null || true
	: >>"$SUPERVISOR_LOCK" 2>/dev/null || true
	rm -f "$DATA_DIR/.stop-requested" 2>/dev/null || true

	# Hard single-instance: one-shot purge orphans, keep healthy 1 panel or spawn one.
	if enforce_single_on_start; then
		ensure_firewall
		open_panel_port_hook
		# Final cull — never leave extra service.sh/sleep after "already running"
		purge_orphans_oneshot
		echo "EngVPN started (port $PORT)"
		return 0
	fi

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

				# 8>&- : do not inherit supervisor flock into engvpnd/node.
				# engvpnd serve exec's into node (same PID) — child is the panel.
				"$DAEMON" serve --data-dir "$DATA_DIR" 8>&- >>"$LOG" 2>&1 &
				child=$!
				printf '%s\n' "$child" >"$PIDFILE"
				while kill -0 "$child" 2>/dev/null; do
					[ -f "$DATA_DIR/.stop-requested" ] && break
					[ -x "$DAEMON" ] || break
					n=$(panel_count)
					if [ "$n" -gt 1 ]; then
						echo "EngVPN supervisor: cull extras ($n panels)" >>"$LOG" 2>/dev/null || true
						cull_extra_panels
					fi
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
				rm -rf "$PANEL_LOCK.d" 2>/dev/null || true
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

	# Progress + hard timeout (default 45s). After panel is up, one-shot purge extras.
	if wait_for_panel; then
		n=$(panel_count)
		[ "$n" -gt 1 ] && cull_extra_panels
		purge_orphans_oneshot
		echo "EngVPN started (port $PORT)"
		return 0
	fi
	echo "EngVPN failed to start (timeout ${ENGVPN_START_TIMEOUT:-45}s) — see $LOG" >&2
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
