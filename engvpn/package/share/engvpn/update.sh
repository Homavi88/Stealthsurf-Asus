#!/bin/sh
# EngVPN self-update from the HTTPS feed (SHA-256), then install.sh upgrade.
#
#   update.sh check              # print installed vs feed version
#   update.sh apply [wait]       # download, verify, upgrade (wait seconds for service, default 60)
set -u

SHARE=$(cd "${0%/*}" 2>/dev/null && pwd -P) || exit 1
PREFIX=${SHARE%/share/engvpn}
VERSION_FILE=$SHARE/VERSION
INSTALL=$SHARE/install.sh
FEED=${ENGVPN_FEED:-https://raw.githubusercontent.com/Homavi88/Stealthsurf-Asus/main/engvpn/feed/latest.json}
PACKAGE_PREFIX=${ENGVPN_PACKAGE_PREFIX:-https://github.com/Homavi88/Stealthsurf-Asus/releases/download/}
WORK=/tmp/engvpn-update.$$
PATH=/opt/bin:/opt/sbin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}
export PATH

fail() {
	echo "update: $*" >&2
	rm -rf "$WORK"
	exit 1
}

installed_version() {
	[ -f "$VERSION_FILE" ] && cat "$VERSION_FILE" || echo "0.0.0"
}

arch_key() {
	case "$(uname -m)" in
	aarch64 | arm64) echo merlin-aarch64 ;;
	armv7* | armv8l*) echo merlin-armv7 ;;
	x86_64 | amd64) echo merlin-x86_64 ;;
	*) fail "unsupported arch $(uname -m)" ;;
	esac
}

fetch_feed() {
	curl -fsS --retry 3 "$FEED" || fail "could not fetch $FEED"
}

field() {
	feed=$1
	key=$2
	name=$3
	printf '%s\n' "$feed" | awk -v key="\"$key\": {" -v name="\"$name\":" '
		index($0, key) { inside = 1; next }
		inside && /^ *}/ { exit }
		inside && index($0, name) {
			value = substr($0, index($0, name) + length(name))
			gsub(/^[ \t]*"|",?[ \t]*$/, "", value)
			print value
			exit
		}'
}

cmd_check() {
	feed=$(fetch_feed)
	ver=$(printf '%s\n' "$feed" | sed -n 's/^  "version": "\([^"]*\)",*$/\1/p' | head -n 1)
	cur=$(installed_version)
	key=$(arch_key)
	url=$(field "$feed" "$key" url)
	echo "installed=$cur"
	echo "feed=$ver"
	echo "arch=$key"
	echo "url=$url"
	if [ -n "$ver" ] && [ "$ver" != "$cur" ]; then
		echo "update_available=1"
		return 0
	fi
	echo "update_available=0"
}

cmd_apply() {
	wait=${1:-60}
	key=$(arch_key)
	feed=$(fetch_feed)
	ver=$(printf '%s\n' "$feed" | sed -n 's/^  "version": "\([^"]*\)",*$/\1/p' | head -n 1)
	url=$(field "$feed" "$key" url)
	sha256=$(field "$feed" "$key" sha256)
	[ -n "$ver" ] && [ -n "$url" ] && [ -n "$sha256" ] || fail "incomplete feed for $key"
	cur=$(installed_version)
	if [ "$ver" = "$cur" ] && [ "${ENGVPN_FORCE_UPDATE:-}" != 1 ]; then
		echo "update: already on $cur"
		exit 0
	fi
	case "$url" in
	https://github.com/* | https://raw.githubusercontent.com/* | "$PACKAGE_PREFIX"* | file://* | http://127.0.0.1/* | http://localhost/*) ;;
	*) fail "refusing URL $url" ;;
	esac
	rm -rf "$WORK"
	mkdir -m 700 "$WORK" || fail "mkdir $WORK"
	archive=$WORK/engvpn.tar.gz
	case "$url" in
	file://*)
		cp -f "${url#file://}" "$archive" || fail "copy failed"
		;;
	*)
		curl -fsS --retry 3 -o "$archive" "$url" || fail "download failed"
		;;
	esac
	if type sha256sum >/dev/null 2>&1; then
		actual=$(sha256sum "$archive" | awk '{ print $1 }')
	else
		actual=$(openssl dgst -sha256 -r "$archive" | awk '{ print $1 }')
	fi
	[ "$actual" = "$sha256" ] || fail "checksum mismatch"
	# Hold transparent rules during upgrade if present
	[ -x "$SHARE/netfilter.sh" ] && sh "$SHARE/netfilter.sh" set-hold 120 >/dev/null 2>&1 || true
	export ENGVPN_SMOKE="${ENGVPN_SMOKE:-}"
	export ENGVPN_SCRIPTS="${ENGVPN_SCRIPTS:-}"
	export ENGVPN_LOCK_DIR="${ENGVPN_LOCK_DIR:-}"
	sh "$INSTALL" upgrade "$archive" "$ver" "$wait" "$PREFIX" || fail "upgrade failed"
	rm -rf "$WORK"
	echo "update: now on $(installed_version)"
}

case "${1:-check}" in
check) cmd_check ;;
apply)
	shift
	cmd_apply "$@"
	;;
*)
	echo "Usage: $0 check|apply [wait]" >&2
	exit 2
	;;
esac
