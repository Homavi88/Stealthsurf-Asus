#!/bin/sh
# EngVPN for Asuswrt-Merlin — install / upgrade / uninstall from a package archive.
#
#   install.sh install <archive> <prefix>
#   install.sh upgrade <archive> <version> <wait> <prefix>
#   install.sh uninstall [<prefix>]
#
# <prefix> is /jffs/addons/engvpn or /tmp/mnt/<drive>/engvpn (ext2/3/4, safe name).
# Does not touch SurfGate (/jffs/addons/ssurf) or official StealthSurf (/jffs/addons/stealthsurf).
set -u
umask 022

SCRIPTS=/jffs/scripts
HOOKS="services-start services-stop post-mount unmount firewall-start nat-start"
MARK="# EngVPN"
VOLATILE_DIR=/tmp/engvpn
WORK=/tmp/engvpn-package
STAGE=$WORK/stage
ROLLBACK=$WORK/rollback
LOCK_DIR=/jffs/addons
LOCK=$LOCK_DIR/.engvpn-install.lock
SERVICE_LOCK=$LOCK_DIR/.engvpn-service.lock
LOCKED=""
PATH=/opt/bin:/opt/sbin:/sbin:/bin:/usr/sbin:/usr/bin
export PATH

# Allow smoke tests off-router
if [ "${ENGVPN_SMOKE:-}" = 1 ]; then
	SCRIPTS=${ENGVPN_SCRIPTS:-/tmp/engvpn-smoke-scripts}
	LOCK_DIR=${ENGVPN_LOCK_DIR:-/tmp/engvpn-smoke-lock}
	LOCK=$LOCK_DIR/.engvpn-install.lock
	SERVICE_LOCK=$LOCK_DIR/.engvpn-service.lock
fi

# Staged progress: merlin.sh sets ENGVPN_STAGE_TOTAL / ENGVPN_STAGE_NUM so
# [n/N] continues across the outer installer. Standalone install uses local totals.
STAGE_TOTAL=${ENGVPN_STAGE_TOTAL:-0}
STAGE_NUM=${ENGVPN_STAGE_NUM:-0}
STAGE_NAME=""

stage() {
	# $1 = short id (for errors), $2 = RU message
	if [ "$STAGE_TOTAL" -gt 0 ] 2>/dev/null; then
		STAGE_NUM=$((STAGE_NUM + 1))
		STAGE_NAME=$1
		echo "[$STAGE_NUM/$STAGE_TOTAL] $2"
	else
		STAGE_NAME=$1
		echo "==> $2"
	fi
}

say() {
	echo "$*"
	logger -t engvpn "$*" 2>/dev/null || true
}

complain() {
	echo "$*" >&2
	logger -t engvpn "$*" 2>/dev/null || true
}

fail() {
	if [ -n "${STAGE_NAME:-}" ]; then
		complain "Ошибка на этапе «$STAGE_NAME»: $*"
	else
		complain "$*"
	fi
	[ -n "$LOCKED" ] && rm -rf "$STAGE"
	exit 1
}

set_prefix() {
	case "$1" in
	*/addons/engvpn | /tmp/engvpn-smoke/engvpn | /tmp/*/engvpn) ;;
	/jffs/addons/engvpn) ;;
	/tmp/mnt/*/engvpn)
		drive=${1#/tmp/mnt/}
		drive=${drive%/engvpn}
		case "$drive" in
		'' | . | .. | *[!A-Za-z0-9._-]*)
			fail "Drive name «$drive» is invalid: use letters, digits, ., _, -"
			;;
		esac
		;;
	*)
		# Smoke / custom absolute paths under ENGVPN_SMOKE
		if [ "${ENGVPN_SMOKE:-}" = 1 ]; then
			case "$1" in
			/*) ;;
			*) fail "Invalid install directory: $1" ;;
			esac
		else
			fail "Invalid install directory: $1"
		fi
		;;
	esac
	PREFIX=$1
	SHARE=$PREFIX/share/engvpn
	MANIFEST=$SHARE/files
	OLD_MANIFEST=$SHARE/files.old
	DAEMON=$PREFIX/sbin/engvpnd
	SERVICE=$SHARE/service.sh
	DATA_DIR=$PREFIX/data
}

owner() {
	# shellcheck disable=SC2012
	ls -ldn "$1" 2>/dev/null | awk '{ print $3 }'
}

private_to_root() {
	[ -d "$1" ] && [ ! -L "$1" ] || return 1
	[ "${ENGVPN_SMOKE:-}" = 1 ] && return 0
	[ "$(owner "$1")" = 0 ] || return 1
	# shellcheck disable=SC2012
	case "$(ls -ld "$1" | cut -c 1-10)" in
	?????w???? | ????????w?) return 1 ;;
	esac
	return 0
}

claim_work() {
	if [ -e "$WORK" ] || [ -L "$WORK" ]; then
		private_to_root "$WORK" || rm -rf "$WORK"
	fi
	[ -d "$WORK" ] || mkdir -m 700 "$WORK" 2>/dev/null
	private_to_root "$WORK" || fail "Could not create $WORK"
}

hold_on() {
	trap '' HUP PIPE INT TERM
}

take_lock() {
	mkdir -p "$LOCK_DIR" || fail "Could not create $LOCK_DIR"
	[ -L "$LOCK" ] && rm -f "$LOCK"
	if type flock >/dev/null 2>&1; then
		if exec 9>"$LOCK" && flock -n 9; then
			LOCKED=1
			return 0
		fi
		complain "Another EngVPN install/update/uninstall is running"
		exit 1
	fi
	# No flock (dev hosts): best-effort lock file
	if [ -f "$LOCK" ]; then
		complain "Lock $LOCK exists; remove if stale"
		exit 1
	fi
	: >"$LOCK"
	LOCKED=1
}

size_of() {
	# shellcheck disable=SC2012
	[ -f "$1" ] && ls -ln "$1" 2>/dev/null | awk '{ print $5 }' || echo 0
}

free_kb() {
	df -k "$1" 2>/dev/null | awk 'NR > 1 && NF >= 5 { value = $(NF - 2) } END { print value }'
}

mode_of() {
	# shellcheck disable=SC2012
	ls -ld "$1" 2>/dev/null | awk '{
		bits = substr($1, 2, 9); mode = 0
		for (i = 1; i <= 9; i++) {
			c = substr(bits, i, 1)
			mode = mode * 2 + (c != "-" && c != "S" && c != "T")
		}
		printf "%o\n", mode
	}'
}

unpack() {
	rm -rf "$STAGE"
	mkdir -m 700 "$STAGE" || return 1
	tar -xzf "$1" -C "$STAGE" || return 1
	[ -f "$STAGE/share/engvpn/files" ] || {
		complain "Archive missing file manifest"
		return 1
	}
	while IFS= read -r file; do
		[ -z "$file" ] && continue
		[ -e "$STAGE/$file" ] || [ -L "$STAGE/$file" ] || {
			complain "Archive missing $file"
			return 1
		}
	done <"$STAGE/share/engvpn/files"
	[ -x "$STAGE/sbin/engvpnd" ] || chmod +x "$STAGE/sbin/engvpnd" 2>/dev/null || true
	# Arch check: shell daemon always "runs"; Node checked later by service.
	sh -n "$STAGE/sbin/engvpnd" 2>/dev/null || {
		complain "engvpnd failed syntax check"
		return 1
	}
	return 0
}

place() {
	if [ -f "$MANIFEST" ]; then
		{
			{ [ -f "$OLD_MANIFEST" ] && cat "$OLD_MANIFEST"; cat "$MANIFEST"; } | sort -u >"$OLD_MANIFEST.new" &&
				mv -f "$OLD_MANIFEST.new" "$OLD_MANIFEST"
		} || {
			rm -f "$OLD_MANIFEST.new"
			return 1
		}
	fi
	while IFS= read -r file; do
		[ -z "$file" ] && continue
		target="$PREFIX/$file"
		mkdir -p "${target%/*}" || return 1
		cp -p "$STAGE/$file" "$target.new" || return 1
		mv -f "$target.new" "$target" || return 1
	done <"$STAGE/share/engvpn/files"
	# Ensure executables
	chmod 0755 "$PREFIX/sbin/engvpnd" \
		"$SHARE/install.sh" "$SHARE/service.sh" "$SHARE/hook.sh" "$SHARE/netfilter.sh" \
		"$SHARE/transparent.sh" "$SHARE/backup.sh" "$SHARE/discover-devices.sh" "$SHARE/smartdns.sh" \
		"$SHARE/dpi.sh" "$SHARE/warp.sh" "$SHARE/update.sh" "$SHARE/schedule-update.sh" 2>/dev/null || true
	if [ -f "$OLD_MANIFEST" ]; then
		while IFS= read -r file; do
			[ -n "$file" ] || continue
			grep -qxF "$file" "$MANIFEST" || rm -f "$PREFIX/$file"
		done <"$OLD_MANIFEST"
		rm -f "$OLD_MANIFEST"
	fi
	return 0
}

enough_room() {
	growth=0
	peak=0
	while IFS= read -r file; do
		[ -z "$file" ] && continue
		new=$(size_of "$STAGE/$file")
		old=$(size_of "$PREFIX/$file")
		[ $((growth + new)) -gt "$peak" ] && peak=$((growth + new))
		growth=$((growth + new - old))
	done <"$STAGE/share/engvpn/files"
	room_need=$((peak / 1024 + 1024))
	free=$(free_kb "$PREFIX")
	[ -z "$free" ] && return 0
	[ "$room_need" -le "$free" ]
}

clear_leftovers() {
	for list in "$MANIFEST" "$OLD_MANIFEST" "$STAGE/share/engvpn/files"; do
		[ -f "$list" ] || continue
		while IFS= read -r file; do
			[ -n "$file" ] && rm -f "$PREFIX/$file.new"
		done <"$list"
	done
	for top in "$PREFIX/sbin" "$PREFIX/share"; do
		[ -d "$top" ] || continue
		find "$top" 2>/dev/null | while IFS= read -r entry; do
			case "$entry" in
			*.new) [ -f "$entry" ] && [ ! -L "$entry" ] && rm -f "$entry" ;;
			esac
		done
	done
}

enable_scripts() {
	[ "${ENGVPN_SMOKE:-}" = 1 ] && return 0
	if type nvram >/dev/null 2>&1 && [ "$(nvram get jffs2_scripts 2>/dev/null)" != 1 ]; then
		nvram set jffs2_scripts=1 && nvram commit >/dev/null 2>&1
	fi
}

script_file() {
	if [ -L "$1" ]; then
		readlink -f "$1" 2>/dev/null || echo "$1"
	else
		echo "$1"
	fi
}

add_hook() {
	line="[ -x \"$SHARE/hook.sh\" ] && \"$SHARE/hook.sh\" $1 \"\$@\" $MARK"
	if [ -f "$2" ]; then
		first=""
		IFS= read -r first <"$2"
		case "$first" in
		'#!'*) from=2 ;;
		*)
			first='#!/bin/sh'
			from=1
			;;
		esac
		printf '%s\n%s\n' "$first" "$line" >"$3" || return 1
		tail -n "+$from" "$2" >"$3.body" || return 1
		if [ -n "${4:-}" ]; then
			awk -v mark="$MARK" -v own="\"$SHARE/hook.sh\"" '!(index($0, mark) && index($0, own))' "$3.body" >>"$3" ||
				return 1
		else
			grep -vF "$MARK" "$3.body" >>"$3"
			[ $? -le 1 ] || return 1
		fi
		rm -f "$3.body"
		mode=$(mode_of "$2")
	else
		printf '#!/bin/sh\n%s\n' "$line" >"$3" || return 1
		mode=755
	fi
	chmod "${mode:-755}" "$3" && chmod u+x "$3" || return 1
	mv -f "$3" "$2"
}

add_hooks() (
	umask 077
	keep_others=""
	[ "${1:-}" = keep-others ] && keep_others=1
	mkdir -p "$SCRIPTS" || exit 1
	for hook in $HOOKS; do
		script=$(script_file "$SCRIPTS/$hook")
		[ -n "$script" ] || exit 1
		temporary=$script.engvpn
		if ! add_hook "$hook" "$script" "$temporary" "$keep_others"; then
			rm -f "$temporary" "$temporary.body"
			exit 1
		fi
	done
)

remove_hooks() (
	umask 077
	own="\"$SHARE/hook.sh\""
	for hook in $HOOKS; do
		name=$SCRIPTS/$hook
		script=$(script_file "$name")
		[ -n "$script" ] && [ -f "$script" ] || continue
		grep -F "$MARK" "$script" 2>/dev/null | grep -qF "$own" || continue
		temporary=$script.engvpn
		awk -v mark="$MARK" -v own="$own" '!(index($0, mark) && index($0, own))' "$script" >"$temporary" || {
			rm -f "$temporary"
			continue
		}
		if [ ! -L "$name" ] && [ "$(grep -cv '^[[:space:]]*\(#.*\)\{0,1\}$' "$temporary")" = 0 ]; then
			rm -f "$name" "$temporary"
		elif ! { chmod "$(mode_of "$script")" "$temporary" && mv -f "$temporary" "$script"; }; then
			rm -f "$temporary"
		fi
	done
)

other_install() {
	for hook in $HOOKS; do
		script=$(script_file "$SCRIPTS/$hook")
		[ -n "$script" ] && [ -f "$script" ] || continue
		grep -F "$MARK" "$script" 2>/dev/null | sed -n 's/^\[ -x "\([^"]*\)\/hook\.sh" \].*/\1/p'
	done | sort -u | while IFS= read -r share; do
		[ "$share" = "$SHARE" ] && continue
		[ -f "$share/hook.sh" ] && echo "$share"
	done | head -n 1
}

start_service() {
	mkdir -p "$DATA_DIR"
	chmod 700 "$DATA_DIR" 2>/dev/null || true
	(
		trap - HUP PIPE INT TERM
		export ENGVPN_SMOKE="${ENGVPN_SMOKE:-}"
		export ENGVPN_LOCK_DIR="${ENGVPN_LOCK_DIR:-}"
		export ENGVPN_SCRIPTS="${ENGVPN_SCRIPTS:-}"
		exec "$SERVICE" restart
	) 6>&- 8>&- 9>&-
}

stop_service() {
	[ -x "$SERVICE" ] || return 0
	"$SERVICE" stop >/dev/null 2>&1 6>&- 8>&- 9>&-
}

running() {
	[ -x "$SERVICE" ] && "$SERVICE" check >/dev/null 2>&1
}

back_up() {
	rm -rf "$ROLLBACK"
	[ -f "$MANIFEST" ] || return 0
	mkdir -p "$ROLLBACK/files" || return 1
	cp -p "$MANIFEST" "$ROLLBACK/manifest" || return 1
	while IFS= read -r file; do
		[ -f "$PREFIX/$file" ] || continue
		mkdir -p "$ROLLBACK/files/${file%/*}" && cp -p "$PREFIX/$file" "$ROLLBACK/files/$file" || return 1
	done <"$MANIFEST"
}

roll_back() {
	stop_service || true
	previous="$ROLLBACK/manifest"
	for list in "$MANIFEST" "$STAGE/share/engvpn/files"; do
		[ -f "$list" ] || continue
		while IFS= read -r file; do
			[ -n "$file" ] || continue
			rm -f "$PREFIX/$file.new"
			if [ ! -f "$previous" ] || ! grep -qxF "$file" "$previous"; then
				rm -f "$PREFIX/$file"
			fi
		done <"$list"
	done
	rm -rf "$STAGE"
	if [ -f "$previous" ]; then
		while IFS= read -r file; do
			[ -f "$ROLLBACK/files/$file" ] || continue
			mkdir -p "$PREFIX/${file%/*}"
			cp -p "$ROLLBACK/files/$file" "$PREFIX/$file" || true
		done <"$previous"
		cp -p "$previous" "$MANIFEST" 2>/dev/null || true
		add_hooks || true
		start_service || true
		return 0
	fi
	remove_hooks
	rm -rf "$PREFIX/sbin" "$PREFIX/share"
}

drive_mount() {
	case "$PREFIX" in
	/tmp/mnt/*) echo "${PREFIX%/engvpn}" ;;
	esac
}

drive_plugged() {
	mount=$(drive_mount)
	[ -z "$mount" ] && return 0
	[ "${ENGVPN_SMOKE:-}" = 1 ] && return 0
	awk -v mount="$mount" '$2 == mount { found = 1 } END { exit !found }' /proc/mounts
}

check_place() {
	mount=$(drive_mount)
	if [ -n "$mount" ] && [ "${ENGVPN_SMOKE:-}" != 1 ]; then
		type=$(awk -v mount="$mount" '$2 == mount { print $3 }' /proc/mounts | tail -n 1)
		case "$type" in
		ext2 | ext3 | ext4) ;;
		'') fail "Drive $mount is not mounted" ;;
		*) fail "Drive $mount is $type: need ext4 (or ext2/ext3)" ;;
		esac
	fi
	if [ ! -e "$PREFIX" ] && [ ! -L "$PREFIX" ]; then
		mkdir -m 755 "$PREFIX" || fail "Could not create $PREFIX"
	fi
}

check_parents() {
	mkdir -p "$LOCK_DIR" 2>/dev/null || true
	[ "${ENGVPN_SMOKE:-}" = 1 ] && return 0
	[ -d /jffs ] || fail "Asuswrt-Merlin with JFFS is required"
}

user_backup() {
	# Persistent user-facing backup (data + package) — separate from /tmp rollback.
	# Prefer already-installed backup.sh; else use the one from the archive stage.
	script=""
	if [ -f "$SHARE/backup.sh" ]; then
		script=$SHARE/backup.sh
	elif [ -n "${STAGE:-}" ] && [ -f "$STAGE/share/engvpn/backup.sh" ]; then
		script=$STAGE/share/engvpn/backup.sh
	fi
	[ -n "$script" ] || return 0
	sh "$script" create "$PREFIX" || complain "user backup failed (continuing)"
}

ask_restore() {
	# Returns 0 if user wants restore. Honours ENGVPN_RESTORE=1|0.
	case "${ENGVPN_RESTORE:-}" in
	1 | yes | YES | y | Y) return 0 ;;
	0 | no | NO | n | N) return 1 ;;
	esac
	if [ "${ENGVPN_SMOKE:-}" = 1 ]; then
		# Smoke default: no restore unless ENGVPN_RESTORE set
		return 1
	fi
	{ : </dev/tty; } 2>/dev/null || {
		complain "no TTY for restore prompt; set ENGVPN_RESTORE=1|0 (default: no restore)"
		return 1
	}
	printf "Восстановить EngVPN из резервной копии (откат)? [y/N]: " >/dev/tty
	ans=""
	IFS= read -r ans </dev/tty || ans=""
	case "$ans" in
	y | Y | yes | YES | да | Да | ДА) return 0 ;;
	esac
	return 1
}

do_install() {
	archive=$1
	stage "Распаковка" "Распаковка пакета…"
	[ -f "$archive" ] || fail "нет архива $archive"
	check_place
	other=$(other_install)
	[ -z "$other" ] || fail "EngVPN уже установлен в ${other%/share/engvpn}"
	unpack "$archive" || fail "не удалось распаковать архив"

	stage "Резервная копия" "Резервная копия…"
	# Snapshot existing data/package before mutating (uses staged backup.sh on first install)
	user_backup
	clear_leftovers
	enough_room || fail "недостаточно места в $PREFIX для новых файлов"
	had_manifest=""
	[ -f "$MANIFEST" ] && had_manifest=1
	if ! back_up; then
		rm -rf "$ROLLBACK"
		fail "недостаточно места в /tmp для резервной копии установленной версии"
	fi
	hold_on
	mkdir -p "$DATA_DIR" && chmod 700 "$DATA_DIR"
	if ! stop_service; then
		[ -n "$had_manifest" ] || rm -rf "$ROLLBACK"
		fail "сервис EngVPN не остановился"
	fi

	stage "Установка файлов" "Установка файлов…"
	problem=""
	if ! place; then
		problem="не удалось установить файлы"
	else
		stage "Хуки" "Хуки пользовательских скриптов…"
		enable_scripts
		if ! add_hooks; then
			problem="не удалось записать скрипты в $SCRIPTS"
		else
			# Copy VERSION into share if present in stage
			[ -f "$STAGE/share/engvpn/VERSION" ] && cp -p "$STAGE/share/engvpn/VERSION" "$SHARE/VERSION"
			# Seed updates.conf + Merlin cru / cron (survives reboot via services-start)
			if [ -x "$SHARE/schedule-update.sh" ]; then
				ENGVPN_DATA_DIR="$DATA_DIR" sh "$SHARE/schedule-update.sh" install-cru >/dev/null 2>&1 || true
			fi
			if [ "${ENGVPN_DEFER_START:-}" = 1 ]; then
				: # merlin.sh starts after saving the panel password
			else
				stage "Запуск" "Запуск сервиса…"
				start_service || problem="сервис EngVPN не запустился"
			fi
		fi
	fi
	if [ -n "$problem" ]; then
		roll_back || fail "$problem, и откат не удался"
		rm -rf "$ROLLBACK"
		fail "$problem: восстановлена предыдущая версия"
	fi
	rm -rf "$ROLLBACK" "$STAGE"
	say "EngVPN установлен в $PREFIX"
}

do_upgrade() {
	archive=$1
	version=$2
	wait=$3
	drive_plugged || fail "Drive not mounted; upgrade aborted"
	[ -x "$DAEMON" ] || fail "No EngVPN at $PREFIX"
	unpack "$archive" || fail "Archive unpack failed"
	user_backup
	clear_leftovers
	enough_room || fail "Not enough space for upgrade"
	back_up || {
		rm -rf "$ROLLBACK"
		fail "Not enough /tmp to back up"
	}
	hold_on
	stop_service || {
		rm -rf "$ROLLBACK" "$STAGE"
		fail "Service did not stop"
	}
	if place && add_hooks; then
		[ -f "$STAGE/share/engvpn/VERSION" ] && cp -p "$STAGE/share/engvpn/VERSION" "$SHARE/VERSION"
		[ -x "$SHARE/schedule-update.sh" ] &&
			ENGVPN_DATA_DIR="$DATA_DIR" sh "$SHARE/schedule-update.sh" install-cru >/dev/null 2>&1 || true
		rm -rf "$STAGE"
		start_service
		waited=0
		while [ "$waited" -lt "$wait" ]; do
			running && break
			sleep 1
			waited=$((waited + 1))
		done
		if ! running && [ -f "$ROLLBACK/manifest" ]; then
			complain "EngVPN $version did not start; rolling back"
			roll_back
			rm -rf "$ROLLBACK"
			return 1
		fi
	else
		complain "Upgrade placement failed; rolling back"
		roll_back
		rm -rf "$ROLLBACK"
		return 1
	fi
	rm -rf "$ROLLBACK"
	say "EngVPN upgraded to $version"
}

do_uninstall() {
	drive_plugged || fail "Drive not mounted; uninstall aborted"
	stop_service || fail "Service did not stop; reboot and retry uninstall"
	if ask_restore; then
		# Roll back to the last pre-install/upgrade snapshot — do NOT overwrite it first.
		bak=$SHARE/backup.sh
		[ -x "$bak" ] || fail "backup.sh missing; cannot restore"
		say "Restoring EngVPN from backup (uninstall cancelled → rollback)"
		remove_hooks
		sh "$bak" restore "$PREFIX" || fail "restore from backup failed"
		add_hooks || complain "hooks restore incomplete"
		start_service || complain "service did not start after restore"
		say "EngVPN restored from backup at $PREFIX"
		return 0
	fi
	# Clean remove: snapshot current state for a later manual restore, then delete.
	if [ "${ENGVPN_SKIP_BACKUP:-}" != 1 ] && [ -x "$SHARE/backup.sh" ]; then
		sh "$SHARE/backup.sh" create "$PREFIX" || complain "pre-uninstall backup failed"
	fi
	[ -x "$SHARE/schedule-update.sh" ] && sh "$SHARE/schedule-update.sh" remove-cru >/dev/null 2>&1 || true
	remove_hooks
	rm -rf "$PREFIX"
	if [ -e "$PREFIX" ] || [ -L "$PREFIX" ]; then
		fail "Could not remove $PREFIX completely"
	fi
	rm -rf "$VOLATILE_DIR"
	rm -rf "$WORK"
	say "EngVPN removed (backup kept under sibling .engvpn-backup unless deleted manually)"
}

own_prefix() {
	share=$(cd "${0%/*}" 2>/dev/null && pwd) || return 1
	echo "${share%/share/engvpn}"
}

case "${1:-}" in
install)
	[ $# -eq 3 ] || fail "Usage: $0 install <archive> <prefix>"
	set_prefix "$3"
	check_parents
	take_lock
	claim_work
	do_install "$2"
	;;
upgrade)
	[ $# -eq 5 ] || fail "Usage: $0 upgrade <archive> <version> <wait> <prefix>"
	set_prefix "$5"
	check_parents
	take_lock
	claim_work
	do_upgrade "$2" "$3" "$4"
	;;
uninstall)
	if [ $# -ge 2 ]; then set_prefix "$2"; else set_prefix "$(own_prefix)"; fi
	check_parents
	take_lock
	hold_on
	do_uninstall
	;;
*)
	echo "Usage: $0 install <archive> <prefix> | upgrade <archive> <version> <wait> <prefix> | uninstall [<prefix>]" >&2
	exit 2
	;;
esac
