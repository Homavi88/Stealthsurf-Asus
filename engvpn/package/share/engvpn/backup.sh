#!/bin/sh
# EngVPN backup / restore — snapshot of prefix data + package files enough to
# restore router/addon state after upgrade or uninstall.
#
#   backup.sh create [<prefix>]
#   backup.sh restore [<prefix>]
#   backup.sh latest [<prefix>]
#   backup.sh list [<prefix>]
#   backup.sh path [<prefix>]
#
# Env:
#   ENGVPN_SKIP_BACKUP=1   — create becomes a no-op
#   ENGVPN_BACKUP_DIR      — override backup root (default: <parent>/.engvpn-backup)
#   ENGVPN_SMOKE=1         — soft paths for smoke tests
set -u

SHARE=$(cd "${0%/*}" 2>/dev/null && pwd -P) || exit 1
DEFAULT_PREFIX=${SHARE%/share/engvpn}
PATH=/opt/bin:/opt/sbin:/sbin:/bin:/usr/sbin:/usr/bin
export PATH

say() { echo "$*"; }
fail() { echo "$*" >&2; exit 1; }

set_prefix() {
	PREFIX=${1:-$DEFAULT_PREFIX}
	case "$PREFIX" in
	/*) ;;
	*) fail "prefix must be absolute: $PREFIX" ;;
	esac
	DATA_DIR=${ENGVPN_DATA_DIR:-$PREFIX/data}
	PARENT=${PREFIX%/*}
	[ -n "$PARENT" ] || PARENT=/
	BACKUP_ROOT=${ENGVPN_BACKUP_DIR:-$PARENT/.engvpn-backup}
	# When prefix is /jffs/addons/engvpn → /jffs/addons/.engvpn-backup
	case "$PREFIX" in
	*/addons/engvpn) BACKUP_ROOT=${ENGVPN_BACKUP_DIR:-${PREFIX%/engvpn}/.engvpn-backup} ;;
	esac
	LATEST=$BACKUP_ROOT/latest
	META=$BACKUP_ROOT/latest.meta
}

stamp() {
	date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date +%Y%m%d%H%M%S
}

ensure_backup_root() {
	mkdir -p "$BACKUP_ROOT" || fail "cannot create $BACKUP_ROOT"
	chmod 700 "$BACKUP_ROOT" 2>/dev/null || true
}

# Collect relative paths under PREFIX that matter for restore.
collect_list() {
	list=$1
	: >"$list"
	# Data tree (configs, state, account, devices, warp, dpi, bypass…)
	if [ -d "$DATA_DIR" ]; then
		(cd "$PREFIX" && find data -type f 2>/dev/null) >>"$list" || true
	fi
	# Installed package files (if present) so restore can roll back binaries
	if [ -f "$PREFIX/share/engvpn/files" ]; then
		while IFS= read -r file || [ -n "$file" ]; do
			[ -z "$file" ] && continue
			[ -e "$PREFIX/$file" ] || [ -L "$PREFIX/$file" ] || continue
			echo "$file" >>"$list"
		done <"$PREFIX/share/engvpn/files"
	fi
	# Always keep VERSION + manifest when present
	for f in share/engvpn/VERSION share/engvpn/files sbin/engvpnd; do
		[ -e "$PREFIX/$f" ] && echo "$f" >>"$list"
	done
	# Deduplicate
	if [ -s "$list" ]; then
		sort -u "$list" -o "$list.tmp" && mv -f "$list.tmp" "$list"
	fi
}

do_create() {
	if [ "${ENGVPN_SKIP_BACKUP:-}" = 1 ]; then
		say "backup: skipped (ENGVPN_SKIP_BACKUP=1)"
		return 0
	fi
	# Nothing to back up yet
	if [ ! -d "$PREFIX" ] && [ ! -L "$PREFIX" ]; then
		say "backup: no existing install at $PREFIX"
		return 0
	fi
	if [ ! -d "$DATA_DIR" ] && [ ! -f "$PREFIX/share/engvpn/files" ] && [ ! -x "$PREFIX/sbin/engvpnd" ]; then
		say "backup: nothing to archive under $PREFIX"
		return 0
	fi
	ensure_backup_root
	ts=$(stamp)
	work=$BACKUP_ROOT/work.$$
	rm -rf "$work"
	mkdir -m 700 "$work" || fail "cannot create work dir"
	list=$work/files
	collect_list "$list"
	if [ ! -s "$list" ]; then
		rm -rf "$work"
		say "backup: empty file list"
		return 0
	fi
	archive=$BACKUP_ROOT/engvpn-backup-$ts.tar.gz
	# Pack from PREFIX
	(
		cd "$PREFIX" || exit 1
		# shellcheck disable=SC2046
		tar -czf "$archive" -T "$list" 2>/dev/null || {
			# BusyBox tar may lack -T: fall back to explicit args
			files=""
			while IFS= read -r f || [ -n "$f" ]; do
				[ -n "$f" ] && [ -e "$f" ] && files="$files $f"
			done <"$list"
			# word-split intentional
			# shellcheck disable=SC2086
			tar -czf "$archive" $files
		}
	) || {
		rm -rf "$work" "$archive"
		fail "backup: tar failed"
	}
	ver=unknown
	[ -f "$PREFIX/share/engvpn/VERSION" ] && ver=$(cat "$PREFIX/share/engvpn/VERSION")
	{
		echo "timestamp=$ts"
		echo "prefix=$PREFIX"
		echo "version=$ver"
		echo "archive=$(basename "$archive")"
		echo "files=$(wc -l <"$list" | tr -d ' ')"
	} >"$META"
	ln -sfn "$(basename "$archive")" "$LATEST" 2>/dev/null || cp -f "$archive" "$LATEST"
	# Keep last 5 archives
	ls -1t "$BACKUP_ROOT"/engvpn-backup-*.tar.gz 2>/dev/null | tail -n +6 | while IFS= read -r old; do
		rm -f "$old"
	done
	rm -rf "$work"
	say "backup: created $archive"
	echo "backup_path=$archive"
	echo "backup_dir=$BACKUP_ROOT"
}

do_restore() {
	ensure_backup_root
	archive=""
	if [ -L "$LATEST" ] || [ -f "$LATEST" ]; then
		if [ -L "$LATEST" ]; then
			target=$(readlink "$LATEST" 2>/dev/null || true)
			case "$target" in
			/*) archive=$target ;;
			*) archive=$BACKUP_ROOT/$target ;;
			esac
		else
			# latest may be a real copy
			archive=$LATEST
		fi
	fi
	[ -f "$archive" ] || fail "backup: no archive to restore (looked in $BACKUP_ROOT)"
	mkdir -p "$PREFIX" || fail "cannot create $PREFIX"
	tar -xzf "$archive" -C "$PREFIX" || fail "backup: restore extract failed"
	# Fix executables
	chmod 0755 "$PREFIX/sbin/engvpnd" 2>/dev/null || true
	for f in install.sh service.sh hook.sh netfilter.sh transparent.sh update.sh schedule-update.sh backup.sh discover-devices.sh smartdns.sh dpi.sh warp.sh; do
		[ -f "$PREFIX/share/engvpn/$f" ] && chmod 0755 "$PREFIX/share/engvpn/$f" 2>/dev/null || true
	done
	say "backup: restored $archive → $PREFIX"
	echo "restored=$archive"
}

do_latest() {
	if [ -f "$META" ]; then
		cat "$META"
	elif [ -e "$LATEST" ]; then
		echo "archive=$LATEST"
	else
		echo "none"
		return 1
	fi
}

do_list() {
	ls -1t "$BACKUP_ROOT"/engvpn-backup-*.tar.gz 2>/dev/null || true
	[ -f "$META" ] && echo "---" && cat "$META"
}

do_path() {
	echo "backup_dir=$BACKUP_ROOT"
	echo "latest=$LATEST"
}

ACTION=${1:-}
case "$ACTION" in
create | restore | latest | list | path)
	shift
	set_prefix "${1:-}"
	do_"$ACTION"
	;;
*)
	echo "Usage: $0 create|restore|latest|list|path [<prefix>]" >&2
	exit 2
	;;
esac
