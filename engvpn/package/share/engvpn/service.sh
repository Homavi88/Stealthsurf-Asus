#!/bin/sh
# EngVPN Merlin service — start/stop/restart/check for the panel daemon.
#
# Single-instance (Merlin CPU / restart storm):
#   1. ONE supervisor per PREFIX — mkdir lockdir (atomic) + flock on
#      $DATA_DIR/.supervisor.lock for the supervisor's entire lifetime.
#   2. ONE node …/run.mjs — engvpnd serve holds $DATA_DIR/.panel.lock (exit 75).
#   3. Per-prefix pid/log under /tmp/engvpn-<hash>/ (never share global pidfiles).
#   4. Supervisor EXITS if engvpnd is missing (exit 127) or DATA_DIR gone —
#      prevents orphan loops after rm -rf / uninstall / USB unmount.
#   5. Racing start NEVER falls into a 45s wait_for_panel waiter swarm —
#      lock losers wait briefly then exit; only the lock holder spawns.
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
LAST_EVENT=$DATA_DIR/last-event
LAST_EVENT_TMP=$VOLATILE_DIR/last-event
KEEPALIVE_CRU=engvpn_alive
KEEPALIVE_MARKER=$DATA_DIR/.keepalive-cru

# Durable breadcrumb: why supervisor/panel last stopped or exited.
# Survives on USB data/; also mirrored under /tmp for when USB is flaky.
record_event() {
	_why=${1:-unknown}
	_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date 2>/dev/null || echo "?")
	mkdir -p "$VOLATILE_DIR" "$DATA_DIR" 2>/dev/null || true
	printf '%s %s\n' "$_ts" "$_why" >"$LAST_EVENT_TMP" 2>/dev/null || true
	printf '%s %s\n' "$_ts" "$_why" >"$LAST_EVENT" 2>/dev/null || true
	echo "EngVPN event: $_why" >>"$LOG" 2>/dev/null || true
}

# External keepalive: Merlin cru every 5 min runs engvpnd watchdog (NOT under
# supervisor). If supervisor died (USB blip, OOM, services-stop without start),
# watchdog restarts service.sh. services-start / do_start re-install (cru is RAM-only).
install_keepalive_cru() {
	mkdir -p "$DATA_DIR" 2>/dev/null || true
	_cmd="[ -x \"$DAEMON\" ] && \"$DAEMON\" watchdog >/dev/null 2>&1"
	# BusyBox ash on some Merlin builds has no `command` builtin — prefer `type`.
	if type cru >/dev/null 2>&1; then
		cru d "$KEEPALIVE_CRU" 2>/dev/null || true
		cru a "$KEEPALIVE_CRU" "*/5 * * * * $_cmd" 2>/dev/null || true
	fi
	printf '%s\n' "*/5 * * * * $_cmd" >"$KEEPALIVE_MARKER" 2>/dev/null || true
}

remove_keepalive_cru() {
	if type cru >/dev/null 2>&1; then
		cru d "$KEEPALIVE_CRU" 2>/dev/null || true
	fi
	rm -f "$KEEPALIVE_MARKER" 2>/dev/null || true
}

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

# Cheap listen check — avoids full /proc sweep on every wait tick.
port_listening() {
	_p=${1:-$PORT}
	case $_p in
	'' | *[!0-9]*) return 1 ;;
	esac
	_hex=$(printf '%04X' "$_p" 2>/dev/null) || return 1
	[ -n "$_hex" ] || return 1
	if [ -r /proc/net/tcp ]; then
		grep -qE ":${_hex} 0+:0+ 0A " /proc/net/tcp 2>/dev/null && return 0
	fi
	if [ -r /proc/net/tcp6 ]; then
		grep -qE ":${_hex} 0+:0+ 0A " /proc/net/tcp6 2>/dev/null && return 0
	fi
	return 1
}

# Node panel only (run.mjs). engvpnd serve parent holds flock and is tracked separately.
own_panel() {
	alive "$1" || return 1
	cmd=$(read_cmdline "$1") || cmd=
	case "$cmd" in
	*"$PREFIX"*run.mjs* | *"$SHARE"/runtime/run.mjs*) return 0 ;;
	*engvpn/share/engvpn/runtime/run.mjs*)
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
# IMPORTANT: ash `$()` / `( )` children keep «service.sh» in argv — never treat
# PPID=$$ helpers as supervisors (cull would SIGKILL them → «Killed» on TTY).
own_service_script() {
	alive "$1" || return 1
	[ "$1" = "$$" ] && return 1
	if [ -r "/proc/$1/status" ]; then
		_pp=
		{ _pp=$(awk '/^PPid:/{print $2; exit}' "/proc/$1/status"); } 2>/dev/null || true
		[ -n "$_pp" ] && [ "$_pp" = "$$" ] && return 1
	fi
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
# NEVER match sleeps whose PPID is $$ — those are wait_for_panel/settle of THIS
# start script (same ENGVPN_* env) and killing them prints «Killed» on the TTY.
is_engvpn_helper() {
	alive "$1" || return 1
	[ "$1" = "$$" ] && return 1
	_pp=
	if [ -r "/proc/$1/status" ]; then
		{ _pp=$(awk '/^PPid:/{print $2; exit}' "/proc/$1/status"); } 2>/dev/null || true
	fi
	[ -n "$_pp" ] && [ "$_pp" = "$$" ] && return 1
	cmd=$(read_cmdline "$1") || return 1
	case "$cmd" in
	sleep\ * | */sleep\ * | sleep) ;;
	*"$DAEMON"*watchdog* | *engvpnd\ watchdog*) ;;
	*) return 1 ;;
	esac
	envtxt=$(read_environ "$1") || return 1
	case "$envtxt" in
	*"ENGVPN_DATA_DIR=$DATA_DIR"* | *"ENGVPN_PIDFILE=$PIDFILE"*) ;;
	*) return 1 ;;
	esac
	# Orphan (PPID=1) or child of a live supervisor / tracked via CHILDREN_FILE.
	[ "$_pp" = 1 ] && return 0
	[ -n "$_pp" ] && own_service_script "$_pp" 2>/dev/null && return 0
	return 1
}

# Fast panel probe: pidfile → lockdir → port → (optional) full scan.
panel_quick_ok() {
	pid=$(read_pid "$PIDFILE" 2>/dev/null || true)
	if [ -n "${pid:-}" ] && own_panel "$pid" 2>/dev/null; then
		return 0
	fi
	if [ -f "$PANEL_LOCK.d/pid" ]; then
		pid=$(read_pid "$PANEL_LOCK.d/pid" 2>/dev/null || true)
		if [ -n "${pid:-}" ] && own_panel "$pid" 2>/dev/null; then
			return 0
		fi
	fi
	port_listening "$PORT" && return 0
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
				kill -9 "$p" 2>/dev/null || true
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
		kill -9 "$p" 2>/dev/null || true
	done
}

# Reap hung sleep/watchdog helpers for this PREFIX (incl. PPID=1 orphans).
kill_orphan_helpers() {
	if [ -f "$CHILDREN_FILE" ]; then
		while read -r cp || [ -n "${cp:-}" ]; do
			case $cp in
			'' | *[!0-9]*) continue ;;
			esac
			[ "$cp" = "$$" ] && continue
			kill -9 "$cp" 2>/dev/null || true
		done <"$CHILDREN_FILE"
		: >"$CHILDREN_FILE" 2>/dev/null || true
	fi
	for entry in /proc/[0-9]*; do
		p=${entry#/proc/}
		is_engvpn_helper "$p" || continue
		kill -9 "$p" 2>/dev/null || true
	done
}

# Path-scoped SIGKILL. Never pkill our own service.sh argv (would kill $$).
brute_kill_prefix() {
	if command -v pkill >/dev/null 2>&1; then
		pkill -9 -f "$PREFIX/share/engvpn/runtime/run.mjs" 2>/dev/null || true
		pkill -9 -f "$PREFIX/sbin/engvpnd serve" 2>/dev/null || true
		pkill -9 -f "$SHARE/runtime/run.mjs" 2>/dev/null || true
	fi
	for entry in /proc/[0-9]*; do
		p=${entry#/proc/}
		[ "$p" = "$$" ] && continue
		cmd=$(read_cmdline "$p") || continue
		case "$cmd" in
		*"$PREFIX"* | *"$SHARE"*)
			case "$cmd" in
			*run.mjs* | *service.sh* | *engvpnd*serve* | *engvpnd\ serve*)
				kill -9 "$p" 2>/dev/null || true
				;;
			esac
			;;
		esac
	done
}

# Lock held by a live supervisor? (lockdir or flock)
supervisor_lock_busy() {
	if [ -d "$SUPERVISOR_LOCK.d" ]; then
		# Stale lockdir if pid dead
		_lp=$(read_pid "$SUPERVISOR_LOCK.d/pid" 2>/dev/null || true)
		if [ -n "${_lp:-}" ] && alive "$_lp"; then
			return 0
		fi
		# No live pid in lockdir — still treat as busy if flock held
		:
	fi
	if type flock >/dev/null 2>&1; then
		if ! (
			flock -n 9 || exit 1
			exit 0
		) 9>>"$SUPERVISOR_LOCK" 2>/dev/null; then
			return 0
		fi
	fi
	# lockdir without live pid and flock free → stale
	if [ -d "$SUPERVISOR_LOCK.d" ]; then
		_lp=$(read_pid "$SUPERVISOR_LOCK.d/pid" 2>/dev/null || true)
		if [ -z "${_lp:-}" ] || ! alive "$_lp"; then
			return 1
		fi
		return 0
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
	if [ -f "$SUPERVISOR_LOCK.d/pid" ]; then
		k=$(read_pid "$SUPERVISOR_LOCK.d/pid" 2>/dev/null || true)
		if [ -n "$k" ] && [ "$k" != "$$" ] && own_service_script "$k" 2>/dev/null; then
			echo "$k"
			return 0
		fi
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
# If keep is unknown, pick one — never mass-kill when pidfile is still racing.
cull_extra_supervisors() {
	keep_sup=$1
	if [ -z "$keep_sup" ]; then
		keep_sup=$(pick_keep_supervisor 2>/dev/null || true)
	fi
	if [ -z "$keep_sup" ]; then
		# No live supervisor matched yet (spawn race) — do not SIGKILL all.
		kill_orphan_helpers
		return 0
	fi
	for entry in /proc/[0-9]*; do
		p=${entry#/proc/}
		[ "$p" = "$$" ] && continue
		[ "$p" = "$keep_sup" ] && continue
		own_service_script "$p" || continue
		kill -9 "$p" 2>/dev/null || true
	done
	kill_orphan_helpers
	printf '%s\n' "$keep_sup" >"$SUPERVISOR_PIDFILE" 2>/dev/null || true
}

# Force-clear every supervisor for this PREFIX (no panel / stuck lock takeover).
wipe_all_supervisors() {
	sup=$(read_pid "$SUPERVISOR_PIDFILE" 2>/dev/null || true)
	[ -n "${sup:-}" ] && [ "$sup" != "$$" ] && kill -9 "$sup" 2>/dev/null || true
	for entry in /proc/[0-9]*; do
		p=${entry#/proc/}
		[ "$p" = "$$" ] && continue
		own_service_script "$p" || continue
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

	if panel_quick_ok || [ "$(panel_count)" -ge 1 ]; then
		n=$(panel_count)
		[ "$n" -gt 1 ] && cull_extra_panels
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
# Returns 0 if panel already healthy / winner owns boot (caller returns success),
# 1 if THIS process must spawn the one supervisor.
# Never leaves a 45s waiter swarm: lock losers wait briefly then exit success/fail
# without spawning a second supervisor.
enforce_single_on_start() {
	mkdir -p "$VOLATILE_DIR" "$DATA_DIR" 2>/dev/null || true
	: >>"$SUPERVISOR_LOCK" 2>/dev/null || true
	: >>"$LOG" 2>/dev/null || true

	purge_orphans_oneshot

	if panel_quick_ok; then
		echo "EngVPN: panel already up — keep" >>"$LOG" 2>/dev/null || true
		purge_orphans_oneshot
		return 0
	fi

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

	if [ "$n" -eq 1 ] || panel_quick_ok; then
		echo "EngVPN: single panel present — keep" >>"$LOG" 2>/dev/null || true
		purge_orphans_oneshot
		return 0
	fi

	# No panel: another start may own the lock — WAIT, do NOT spawn a loser.
	if supervisor_lock_busy || supervisor_pid >/dev/null; then
		echo "EngVPN: lock held — waiting for winner panel (no spawn)" >>"$LOG" 2>/dev/null || true
		# Bounded wait (same budget as start timeout); no second supervisor.
		if wait_for_panel quiet; then
			purge_orphans_oneshot
			return 0
		fi
		# Winner failed to produce a panel — take over.
		echo "EngVPN: winner timeout — force purge and spawn one" >>"$LOG" 2>/dev/null || true
		purge_orphans_oneshot force
		return 1
	fi

	# Clean slate — spawn one supervisor
	return 1
}

# Tracked sleep so EXIT trap / kill-strays can reap after SIGKILL reparent.
# Close flock fd 8; rewrite children file (do not grow forever).
supervisor_sleep() {
	_secs=$1
	sleep "$_secs" 8>&- &
	_sp=$!
	printf '%s\n' "$_sp" >"$CHILDREN_FILE" 2>/dev/null || true
	wait "$_sp" 2>/dev/null || true
}

is_engvpn_process() {
	own_panel "$1" || own_service_script "$1" || own_engvpnd_serve "$1" || is_engvpn_helper "$1"
}

# Fast stop: path-scoped SIGKILL, one /proc pass, ≤1s settle. No nested O(n²) scans.
kill_strays() {
	mkdir -p "$VOLATILE_DIR" "$DATA_DIR" 2>/dev/null || true
	record_event "stop-requested:kill-strays"
	touch "$DATA_DIR/.stop-requested" 2>/dev/null || true

	kill_dead_prefix_supervisors
	kill_orphan_helpers

	sup=$(read_pid "$SUPERVISOR_PIDFILE" 2>/dev/null || true)
	[ -n "${sup:-}" ] && [ "$sup" != "$$" ] && kill -9 "$sup" 2>/dev/null || true
	pid=$(read_pid "$PIDFILE" 2>/dev/null || true)
	[ -n "${pid:-}" ] && kill -9 "$pid" 2>/dev/null || true
	if [ -f "$PANEL_LOCK.d/pid" ]; then
		pp=$(read_pid "$PANEL_LOCK.d/pid" 2>/dev/null || true)
		[ -n "${pp:-}" ] && [ "$pp" != "$$" ] && kill -9 "$pp" 2>/dev/null || true
	fi
	if [ -f "$SUPERVISOR_LOCK.d/pid" ]; then
		sp=$(read_pid "$SUPERVISOR_LOCK.d/pid" 2>/dev/null || true)
		[ -n "${sp:-}" ] && [ "$sp" != "$$" ] && kill -9 "$sp" 2>/dev/null || true
	fi

	brute_kill_prefix

	# One more /proc sweep (skip $$) — SIGKILL only, no nested child scans
	for entry in /proc/[0-9]*; do
		p=${entry#/proc/}
		[ "$p" = "$$" ] && continue
		if is_engvpn_process "$p"; then
			kill -9 "$p" 2>/dev/null || true
		fi
	done
	kill_orphan_helpers

	rm -f "$PIDFILE" "$SUPERVISOR_PIDFILE" "$CHILDREN_FILE" "$DATA_DIR/.stop-requested"
	rm -rf "$PANEL_LOCK.d" "$SUPERVISOR_LOCK.d" 2>/dev/null || true

	# Best-effort free .supervisor.lock — max 1s
	if type flock >/dev/null 2>&1; then
		if ! (
			flock -n 9 || exit 1
			exit 0
		) 9>>"$SUPERVISOR_LOCK" 2>/dev/null; then
			brute_kill_prefix
			kill_orphan_helpers
			sleep 1
		fi
	fi
}

cull_extra_panels() {
	keep=$(daemon_pid || true)
	[ -n "$keep" ] || return 0
	for entry in /proc/[0-9]*; do
		p=${entry#/proc/}
		[ "$p" = "$keep" ] && continue
		own_panel "$p" || continue
		kill -9 "$p" 2>/dev/null || true
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

# Wait for panel with progress; ENGVPN_START_TIMEOUT seconds (default 20).
# Prefer cheap probes (pidfile/port); full /proc scan at most every 3s.
wait_for_panel() {
	_timeout=${ENGVPN_START_TIMEOUT:-20}
	case $_timeout in
	'' | *[!0-9]*) _timeout=20 ;;
	esac
	[ "$_timeout" -lt 5 ] && _timeout=5
	_i=0
	_quiet=${1:-}
	_full=0
	while [ "$_i" -lt "$_timeout" ]; do
		if panel_quick_ok; then
			[ -z "$_quiet" ] && [ "$_i" -gt 0 ] && printf '\n'
			return 0
		fi
		# Full scan every 3rd tick only (expensive on Merlin)
		_full=$((_full + 1))
		if [ "$_full" -ge 3 ]; then
			_full=0
			n=$(panel_count)
			if [ "$n" -ge 1 ]; then
				[ "$n" -gt 1 ] && cull_extra_panels
				[ -z "$_quiet" ] && [ "$_i" -gt 0 ] && printf '\n'
				return 0
			fi
		fi
		if [ -z "$_quiet" ]; then
			if [ "$_i" -eq 0 ]; then
				printf '  ожидание панели'
			fi
			printf '.'
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

spawn_supervisor() {
	export ENGVPN_IN_SUPERVISOR=1
	if type flock >/dev/null 2>&1; then
		(
		(
			trap '' HUP
			trap 'kill_children_of $$; kill_orphan_helpers; rm -f "$SUPERVISOR_PIDFILE" "$CHILDREN_FILE"; rm -rf "$SUPERVISOR_LOCK.d" 2>/dev/null || true' EXIT
			# Atomic slot: mkdir first (works even when flock is a no-op), then flock.
			if ! mkdir "$SUPERVISOR_LOCK.d" 2>/dev/null; then
				echo "EngVPN supervisor: lockdir busy — not starting another" >>"$LOG" 2>/dev/null || true
				exit 0
			fi
			printf '%s\n' "$$" >"$SUPERVISOR_LOCK.d/pid" 2>/dev/null || true
			flock -n 8 || {
				echo "EngVPN supervisor: flock busy — not starting another" >>"$LOG" 2>/dev/null || true
				rm -rf "$SUPERVISOR_LOCK.d" 2>/dev/null || true
				exit 0
			}
			: >"$CHILDREN_FILE" 2>/dev/null || true
			printf '%s\n' "$$" >"$SUPERVISOR_PIDFILE"
			echo "EngVPN supervisor $$ holding $SUPERVISOR_LOCK prefix=$PREFIX" >>"$LOG" 2>/dev/null || true
			record_event "supervisor-start:pid=$$"
			ticks=0
			_exit_why=
			while :; do
				if [ -f "$DATA_DIR/.stop-requested" ]; then
					_exit_why="stop-requested"
					break
				fi
				# USB / I/O blip: retry ~30s before permanent exit (keepalive cru recovers if we still die).
				if [ ! -x "$DAEMON" ] || [ ! -d "$DATA_DIR" ]; then
					_miss=0
					while [ "$_miss" -lt 6 ]; do
						echo "EngVPN supervisor: daemon/data missing — retry $((_miss + 1))/6" >>"$LOG" 2>/dev/null || true
						supervisor_sleep 5
						[ -x "$DAEMON" ] && [ -d "$DATA_DIR" ] && break
						_miss=$((_miss + 1))
					done
					if [ ! -x "$DAEMON" ] || [ ! -d "$DATA_DIR" ]; then
						_exit_why="daemon-or-data-gone"
						echo "EngVPN supervisor: daemon/data gone — exit" >>"$LOG" 2>/dev/null || true
						break
					fi
				fi

				if panel_quick_ok; then
					n=1
				else
					n=$(panel_count)
				fi
				if [ "$n" -gt 1 ]; then
					echo "EngVPN supervisor: cull extras ($n)" >>"$LOG" 2>/dev/null || true
					cull_extra_panels
					n=$(panel_count)
				fi
				kill_orphan_helpers

				if [ "$n" -ge 1 ] || panel_quick_ok; then
					pid=$(daemon_pid || true)
					[ -n "${pid:-}" ] && printf '%s\n' "$pid" >"$PIDFILE"
					supervisor_sleep 5
					ticks=$((ticks + 5))
					if [ "$ticks" -ge 60 ]; then
						ticks=0
						# Never nest service.sh start from watchdog under supervisor
						ENGVPN_IN_SUPERVISOR=1 "$DAEMON" watchdog 8>&- >>"$LOG" 2>&1 || true
					fi
					continue
				fi

				"$DAEMON" serve --data-dir "$DATA_DIR" 8>&- >>"$LOG" 2>&1 &
				child=$!
				printf '%s\n' "$child" >"$PIDFILE"
				while kill -0 "$child" 2>/dev/null; do
					if [ -f "$DATA_DIR/.stop-requested" ]; then
						_exit_why="stop-requested"
						break
					fi
					[ -x "$DAEMON" ] || break
					if panel_quick_ok; then
						:
					else
						n=$(panel_count)
						if [ "$n" -gt 1 ]; then
							echo "EngVPN supervisor: cull extras ($n panels)" >>"$LOG" 2>/dev/null || true
							cull_extra_panels
						fi
					fi
					supervisor_sleep 5
					ticks=$((ticks + 5))
					if [ "$ticks" -ge 60 ]; then
						ticks=0
						ENGVPN_IN_SUPERVISOR=1 "$DAEMON" watchdog 8>&- >>"$LOG" 2>&1 || true
					fi
				done
				wait "$child" 2>/dev/null
				code=$?
				rm -f "$PIDFILE"
				rm -rf "$PANEL_LOCK.d" 2>/dev/null || true
				[ -n "${_exit_why:-}" ] && break
				if [ -f "$DATA_DIR/.stop-requested" ]; then
					_exit_why="stop-requested"
					break
				fi
				if [ ! -x "$DAEMON" ] || [ ! -d "$DATA_DIR" ]; then
					_exit_why="daemon-or-data-gone-after-child"
					echo "EngVPN supervisor: daemon/data gone after child — exit" >>"$LOG" 2>/dev/null || true
					break
				fi
				if [ "$code" = 127 ]; then
					_exit_why="engvpnd-missing-127"
					echo "EngVPN supervisor: engvpnd missing (127) — exit" >>"$LOG" 2>/dev/null || true
					break
				fi
				if [ "$code" = "$DUP_EXIT" ] || [ "$code" = 75 ]; then
					echo "EngVPN panel duplicate (exit $code); back off 15s" >>"$LOG" 2>/dev/null || true
					supervisor_sleep 15
					continue
				fi
				record_event "panel-exited:code=$code"
				echo "EngVPN panel exited ($code); restart in 5s" >>"$LOG" 2>/dev/null || true
				supervisor_sleep 5
			done
			record_event "supervisor-exit:${_exit_why:-loop-end}"
			rm -f "$SUPERVISOR_PIDFILE" "$CHILDREN_FILE"
			rm -rf "$SUPERVISOR_LOCK.d" 2>/dev/null || true
		# Double-fork: supervisor is not a job of this start script (no «Killed» on TTY).
		) 8>>"$SUPERVISOR_LOCK" >>"$LOG" 2>&1 &
		exit 0
		) >/dev/null 2>&1 &
		wait $! 2>/dev/null || true
	else
		(
		(
			trap '' HUP
			trap 'kill_children_of $$; kill_orphan_helpers; rm -f "$SUPERVISOR_PIDFILE" "$CHILDREN_FILE"; rmdir "$SUPERVISOR_LOCK.d" 2>/dev/null || true' EXIT
			if ! mkdir "$SUPERVISOR_LOCK.d" 2>/dev/null; then
				echo "EngVPN supervisor: lockdir busy — not starting another" >>"$LOG" 2>/dev/null || true
				exit 0
			fi
			printf '%s\n' "$$" >"$SUPERVISOR_LOCK.d/pid" 2>/dev/null || true
			: >"$CHILDREN_FILE" 2>/dev/null || true
			printf '%s\n' "$$" >"$SUPERVISOR_PIDFILE"
			record_event "supervisor-start:pid=$$:noflock"
			_exit_why=
			while :; do
				if [ -f "$DATA_DIR/.stop-requested" ]; then
					_exit_why="stop-requested"
					break
				fi
				if [ ! -x "$DAEMON" ] || [ ! -d "$DATA_DIR" ]; then
					_miss=0
					while [ "$_miss" -lt 6 ]; do
						supervisor_sleep 5
						[ -x "$DAEMON" ] && [ -d "$DATA_DIR" ] && break
						_miss=$((_miss + 1))
					done
					if [ ! -x "$DAEMON" ] || [ ! -d "$DATA_DIR" ]; then
						_exit_why="daemon-or-data-gone"
						break
					fi
				fi
				if panel_quick_ok; then
					n=1
				else
					n=$(panel_count)
				fi
				[ "$n" -gt 1 ] && cull_extra_panels
				kill_orphan_helpers
				if [ "$n" -ge 1 ] || panel_quick_ok; then
					pid=$(daemon_pid || true)
					[ -n "${pid:-}" ] && printf '%s\n' "$pid" >"$PIDFILE"
					supervisor_sleep 5
					continue
				fi
				"$DAEMON" serve --data-dir "$DATA_DIR" >>"$LOG" 2>&1 &
				child=$!
				printf '%s\n' "$child" >"$PIDFILE"
				while kill -0 "$child" 2>/dev/null; do
					if [ -f "$DATA_DIR/.stop-requested" ]; then
						_exit_why="stop-requested"
						break
					fi
					[ -x "$DAEMON" ] || break
					supervisor_sleep 5
				done
				wait "$child" 2>/dev/null
				code=$?
				rm -f "$PIDFILE"
				[ -n "${_exit_why:-}" ] && break
				[ -f "$DATA_DIR/.stop-requested" ] && _exit_why="stop-requested" && break
				[ ! -x "$DAEMON" ] && _exit_why="daemon-gone" && break
				[ "$code" = 127 ] && _exit_why="engvpnd-missing-127" && break
				[ "$code" = 75 ] && supervisor_sleep 15 && continue
				record_event "panel-exited:code=$code"
				supervisor_sleep 5
			done
			record_event "supervisor-exit:${_exit_why:-loop-end}"
			rm -f "$SUPERVISOR_PIDFILE" "$CHILDREN_FILE"
			rmdir "$SUPERVISOR_LOCK.d" 2>/dev/null || true
		) >>"$LOG" 2>&1 &
		exit 0
		) >/dev/null 2>&1 &
		wait $! 2>/dev/null || true
	fi
}

do_start() {
	set +m 2>/dev/null || true
	mkdir -p "$VOLATILE_DIR" "$DATA_DIR"
	chmod 700 "$DATA_DIR" 2>/dev/null || true
	: >>"$LOG" 2>/dev/null || true
	: >>"$SUPERVISOR_LOCK" 2>/dev/null || true
	rm -f "$DATA_DIR/.stop-requested" 2>/dev/null || true
	record_event "start-requested"
	install_keepalive_cru

	if enforce_single_on_start; then
		ensure_firewall
		open_panel_port_hook
		purge_orphans_oneshot
		record_event "start-ok:already-up"
		echo "EngVPN started (port $PORT)"
		return 0
	fi

	[ -x "$DAEMON" ] || {
		record_event "start-fail:missing-daemon"
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

	spawn_supervisor

	# Settle SUPERVISOR_PIDFILE before cull (avoid killing the supervisor we just spawned).
	_s=0
	while [ "$_s" -lt 2 ]; do
		supervisor_pid >/dev/null && break
		# Tiny yield without burning a full start-timeout second when pidfile is ready.
		sleep 1
		_s=$((_s + 1))
	done

	if wait_for_panel; then
		n=$(panel_count)
		[ "$n" -gt 1 ] && cull_extra_panels
		purge_orphans_oneshot
		# Final hard cull: at most one service.sh for this PREFIX (besides $$ which exits)
		keep_sup=$(pick_keep_supervisor 2>/dev/null || true)
		cull_extra_supervisors "$keep_sup"
		record_event "start-ok:spawned"
		echo "EngVPN started (port $PORT)"
		return 0
	fi
	record_event "start-fail:timeout-${ENGVPN_START_TIMEOUT:-20}s"
	echo "EngVPN failed to start (timeout ${ENGVPN_START_TIMEOUT:-20}s) — see $LOG" >&2
	# Hint common recovery when engvpnd start was the wrong verb historically
	echo "EngVPN: if CLI said unknown command, use: $SHARE/service.sh start" >&2
	return 1
}

do_stop() {
	mkdir -p "$DATA_DIR" "$VOLATILE_DIR" 2>/dev/null || true
	record_event "stop-requested:do_stop"
	kill_strays 2>/dev/null || true
	rm -f "$PANEL_LOCK" 2>/dev/null || true
	echo "EngVPN stopped"
}

do_check() {
	if panel_quick_ok; then
		n=$(panel_count)
		if [ "$n" -gt 1 ]; then
			echo "running (WARNING: $n panels)"
			return 0
		fi
		echo "running"
		return 0
	fi
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
	# Snappy: SIGKILL storm clear, no long settle, then one start.
	do_stop
	do_start
	;;
check | status) do_check ;;
kill | kill-strays)
	kill_strays 2>/dev/null || true
	kill_dead_prefix_supervisors 2>/dev/null || true
	echo "EngVPN strays killed"
	;;
install-keepalive)
	install_keepalive_cru
	echo "EngVPN keepalive cru installed ($KEEPALIVE_CRU)"
	;;
remove-keepalive)
	remove_keepalive_cru
	echo "EngVPN keepalive cru removed"
	;;
*)
	echo "Usage: $0 start|stop|restart|check|kill-strays|install-keepalive|remove-keepalive" >&2
	exit 2
	;;
esac
