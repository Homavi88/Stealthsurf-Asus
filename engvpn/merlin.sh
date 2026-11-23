#!/bin/sh
# Installs EngVPN on an Asuswrt-Merlin router over SSH:
#
#   curl -fsSL https://raw.githubusercontent.com/Homavi88/Stealthsurf-Asus/main/engvpn/merlin.sh | sh
#
# Reads the router feed, picks this router's package, checks SHA-256, runs the
# package install.sh, then asks for the panel password. Installs to JFFS
# (/jffs/addons/engvpn) or an ext USB drive when JFFS is full
# (ENGVPN_PREFIX overrides).
#
# Open reimplementation — does not ship StealthSurf proprietary binaries.
# Requires Entware Node.js for the panel runtime (opkg install node).

set -u

# Default feed: GitHub raw of this repo's feed (override for CDN).
FEED=${ENGVPN_FEED:-https://raw.githubusercontent.com/Homavi88/Stealthsurf-Asus/main/engvpn/feed/latest.json}
PACKAGE_PREFIX=${ENGVPN_PACKAGE_PREFIX:-https://github.com/Homavi88/Stealthsurf-Asus/releases/download/}
JFFS_PREFIX=/jffs/addons/engvpn
WORK=""
MIN_MEMORY_KB=230000
MIN_FREE_KB=20480
MIN_UPDATE_FREE_KB=10240
MIN_TMP_FREE_KB=32768

fail() {
	echo "Error: $*" >&2
	exit 1
}

trap '[ -n "$WORK" ] && rm -rf "$WORK"' EXIT
trap '{ type stty >/dev/null 2>&1 && stty echo </dev/tty; } 2>/dev/null; exit 1' INT TERM HUP

free_kb() {
	df -k "$1" 2>/dev/null | awk 'NR > 1 && NF >= 5 { value = $(NF - 2) } END { print value }'
}

# Off-router smoke / packaging hosts can skip Merlin and root checks.
if [ "${ENGVPN_SMOKE:-}" != 1 ]; then
	uid=$(awk '/^Uid:/ { print $3 }' /proc/self/status)
	[ "$uid" = 0 ] || fail "run this script as the router administrator (root)"
	type nvram >/dev/null 2>&1 && [ -d /jffs ] || fail "this is not an ASUS firmware with JFFS"
	uname -o 2>/dev/null | grep -qi merlin || [ -f /usr/sbin/helper.sh ] ||
		fail "Asuswrt-Merlin is required (stock ASUS has no user scripts)"
fi

case "$(uname -m)" in
aarch64 | arm64) key=merlin-aarch64 ;;
armv7* | armv8l*) key=merlin-armv7 ;;
x86_64 | amd64)
	# Dev / smoke host
	key=merlin-x86_64
	;;
*) fail "CPU $(uname -m) is not supported yet: need ARM64, ARMv7, or x86_64 (dev)" ;;
esac

release=$(uname -r)
major=${release%%.*}
minor=${release#*.}
minor=${minor%%.*}
if [ "${ENGVPN_SMOKE:-}" != 1 ]; then
	if [ "${major:-0}" -lt 3 ] || { [ "$major" -eq 3 ] && [ "${minor:-0}" -lt 2 ]; }; then
		fail "Linux kernel $release is too old (need 4.1+)"
	fi
	memory=$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)
	[ "${memory:-0}" -ge "$MIN_MEMORY_KB" ] || fail "need at least 256 MB RAM"
	tmp=$(free_kb /tmp)
	[ -z "$tmp" ] || [ "$tmp" -ge "$MIN_TMP_FREE_KB" ] ||
		fail "/tmp has $((tmp / 1024)) MB free; need $((MIN_TMP_FREE_KB / 1024)) MB"
fi

installed() {
	[ -x "$1/sbin/engvpnd" ]
}

leftovers_kb() {
	for top in "$1/sbin" "$1/share/engvpn"; do
		[ -d "$top" ] && find "$top" 2>/dev/null
	done | while IFS= read -r file; do
		[ -f "$file" ] && [ ! -L "$file" ] || continue
		case "$file" in
		*.new) ;;
		"$1/sbin/engvpnd" | "$1/share/engvpn/"*)
			installed "$1" && continue
			;;
		*) continue ;;
		esac
		# shellcheck disable=SC2012
		ls -ln "$file" | awk '{ print $5 }'
	done | awk '{ total += $1 } END { print int(total / 1024) }'
}

drives() {
	awk '$2 ~ "^/tmp/mnt/[A-Za-z0-9._-]+$" && $3 ~ "^ext[234]$" { print $2 }' /proc/mounts
}

prefix=${ENGVPN_PREFIX:-}
if [ -z "$prefix" ]; then
	installed "$JFFS_PREFIX" && prefix=$JFFS_PREFIX
fi
if [ -z "$prefix" ]; then
	for mount in $(drives); do
		installed "$mount/engvpn" && prefix=$mount/engvpn && break
	done
fi
if [ -z "$prefix" ]; then
	if [ "${ENGVPN_SMOKE:-}" = 1 ]; then
		prefix=${ENGVPN_PREFIX_DEFAULT:-/tmp/engvpn-smoke/engvpn}
	else
		free=$(free_kb /jffs)
		[ -n "$free" ] && free=$((free + $(leftovers_kb "$JFFS_PREFIX")))
		if [ -n "$free" ] && [ "$free" -ge "$MIN_FREE_KB" ]; then
			prefix=$JFFS_PREFIX
		else
			for mount in $(drives); do
				drive=$(free_kb "$mount")
				[ -n "$drive" ] && drive=$((drive + $(leftovers_kb "$mount/engvpn")))
				if [ -n "$drive" ] && [ "$drive" -ge "$MIN_FREE_KB" ]; then
					prefix=$mount/engvpn
					break
				fi
			done
		fi
		[ -n "$prefix" ] ||
			fail "JFFS has $((${free:-0} / 1024)) MB free; need $((MIN_FREE_KB / 1024)) MB. Free space or attach an ext4 USB drive"
	fi
else
	case "$prefix" in
	/*) ;;
	*) fail "Invalid install directory: $prefix" ;;
	esac
	probe_dir=${prefix%/engvpn}
	while [ ! -d "$probe_dir" ] && [ -n "$probe_dir" ] && [ "$probe_dir" != "/" ]; do
		parent=${probe_dir%/*}
		[ "$parent" = "$probe_dir" ] && break
		probe_dir=$parent
	done
	free=$(free_kb "${probe_dir:-/}")
	[ -n "$free" ] && free=$((free + $(leftovers_kb "$prefix")))
	need=$MIN_FREE_KB
	room=$free
	if installed "$prefix"; then
		need=$MIN_UPDATE_FREE_KB
	fi
	if [ -n "$room" ] && [ "$room" -lt "$need" ]; then
		fail "${prefix%/engvpn} has $((free / 1024)) MB free; need at least $((need / 1024)) MB"
	fi
fi

# Panel password before any mutation (unless ENGVPN_PASSWORD is preset for automation).
password=${ENGVPN_PASSWORD:-}
if [ -z "$password" ]; then
	{ : </dev/tty; } 2>/dev/null ||
		fail "no TTY for panel password: use ssh -t, or set ENGVPN_PASSWORD for non-interactive install"
	echo "Choose an EngVPN panel password (keeps guests on your LAN out of the panel)"
	hidden_read() {
		if type stty >/dev/null 2>&1; then
			stty -echo </dev/tty 2>/dev/null
			rc=0
			IFS= read -r "$1" </dev/tty || rc=$?
			stty echo </dev/tty 2>/dev/null
			return "$rc"
		else
			# shellcheck disable=SC3045
			IFS= read -rs "$1" </dev/tty
		fi
	}
	c1_control() {
		hexdump -v -e '1/1 "%u\n"' <<EOF | awk 'previous == 194 && $1 >= 128 && $1 <= 159 { found = 1 } { previous = $1 } END { exit !found }'
$password
EOF
	}
	while :; do
		printf "Password (8–128 characters): "
		password=""
		hidden_read password || fail "could not read password"
		echo
		bytes=$(wc -c <<EOF
$password
EOF
)
		length=$(LC_ALL=C tr -d '\200-\277' <<EOF | wc -c
$password
EOF
)
		printable=$(LC_ALL=C tr -d '\001-\037\177' <<EOF | wc -c
$password
EOF
)
		bytes=$((bytes - 1))
		length=$((length - 1))
		if [ "$((length))" -lt 8 ] || [ "$((length))" -gt 128 ]; then
			echo "Password must be 8–128 characters"
			continue
		fi
		if [ "$((printable))" -ne "$((bytes))" ] || c1_control; then
			echo "Password must not contain control characters"
			continue
		fi
		printf "Again: "
		confirmation=""
		hidden_read confirmation || fail "could not read password"
		echo
		case $confirmation in
		"$password") break ;;
		esac
		echo "Passwords do not match"
	done
fi

WORK=/tmp/engvpn-get.$$
rm -rf "$WORK"
mkdir -m 700 "$WORK" || fail "could not create work dir in /tmp"

# Local package override for offline / smoke installs
if [ -n "${ENGVPN_LOCAL_PACKAGE:-}" ] && [ -f "$ENGVPN_LOCAL_PACKAGE" ]; then
	archive=$ENGVPN_LOCAL_PACKAGE
	version=${ENGVPN_LOCAL_VERSION:-local}
	echo "Using local package $archive"
else
	echo "Reading EngVPN version feed…"
	feed=$(curl -fsS --retry 3 "$FEED") || fail "could not download $FEED"
	field() {
		printf '%s\n' "$feed" | awk -v key="\"$key\": {" -v name="\"$1\":" '
			index($0, key) { inside = 1; next }
			inside && /^ *}/ { exit }
			inside && index($0, name) {
				value = substr($0, index($0, name) + length(name))
				gsub(/^[ \t]*"|",?[ \t]*$/, "", value)
				print value
				exit
			}'
	}
	version=$(printf '%s\n' "$feed" | sed -n 's/^  "version": "\([^"]*\)",*$/\1/p' | head -n 1)
	url=$(field url)
	sha256=$(field sha256)
	[ -n "$version" ] && [ -n "$url" ] && [ -n "$sha256" ] ||
		fail "feed has no package for $key"
	# Allow GitHub release URLs or configured prefix
	case "$url" in
	https://github.com/* | https://raw.githubusercontent.com/* | "$PACKAGE_PREFIX"* | http://127.0.0.1/* | http://localhost/*) ;;
	*)
		# Also allow file:// for smoke
		case "$url" in
		file://*) ;;
		*) fail "package URL must be under an allowed HTTPS host (got $url)" ;;
		esac
		;;
	esac
	echo "Downloading EngVPN $version…"
	archive=$WORK/engvpn.tar.gz
	case "$url" in
	file://*)
		src=${url#file://}
		cp -f "$src" "$archive" || fail "could not copy $src"
		;;
	*)
		curl -fsS --retry 3 -o "$archive" "$url" || fail "could not download package"
		;;
	esac
	if type sha256sum >/dev/null 2>&1; then
		actual=$(sha256sum "$archive" | awk '{ print $1 }')
	else
		actual=$(openssl dgst -sha256 -r "$archive" | awk '{ print $1 }')
	fi
	[ "$actual" = "$sha256" ] || fail "package checksum does not match the feed"
	# Minisign (optional but preferred when feed publishes .minisig)
	sig_url=$(field minisig)
	[ -z "$sig_url" ] && sig_url="${url}.minisig"
	sig=$WORK/engvpn.tar.gz.minisig
	case "$sig_url" in
	file://*) [ -f "${sig_url#file://}" ] && cp -f "${sig_url#file://}" "$sig" || true ;;
	https://* | http://127.0.0.1/* | http://localhost/*)
		curl -fsS --retry 2 -o "$sig" "$sig_url" 2>/dev/null || true
		;;
	esac
	if [ -f "$sig" ]; then
		# Extract pubkey from package for verify (bootstrap chicken/egg: use embedded feed pubkey via curl raw, or skip until after unpack)
		# For first install we verify with known public key from the repo feed tree when available.
		pub_url=${ENGVPN_MINISIGN_PUB:-https://raw.githubusercontent.com/Homavi88/Stealthsurf-Asus/main/engvpn/keys/engvpn.minisign.pub}
		pub=$WORK/engvpn.minisign.pub
		curl -fsS --retry 2 -o "$pub" "$pub_url" 2>/dev/null || true
		if [ -f "$pub" ] && command -v minisign >/dev/null 2>&1; then
			minisign -Vm "$archive" -x "$sig" -p "$pub" || fail "minisign verification failed"
			echo "Minisign OK"
		elif [ -f "$pub" ] && command -v node >/dev/null 2>&1; then
			# Defer full Node verify until package has verify-minisign.mjs — SHA-256 already checked
			echo "Minisign signature present (Node verify after install)"
		else
			echo "Note: minisig present but verifier unavailable; SHA-256 already checked"
		fi
	fi
fi

tar -xzOf "$archive" ./share/engvpn/install.sh >"$WORK/install.sh" ||
	fail "package has no installer"
chmod +x "$WORK/install.sh"

# Hint: Node is required at runtime
if ! { [ -x /opt/bin/node ] || command -v node >/dev/null 2>&1; }; then
	echo "Note: EngVPN panel needs Node.js (Entware: opkg update && opkg install node)"
fi

trap ':' INT TERM HUP
# Pass smoke env through
export ENGVPN_SMOKE="${ENGVPN_SMOKE:-}"
export ENGVPN_SCRIPTS="${ENGVPN_SCRIPTS:-}"
export ENGVPN_LOCK_DIR="${ENGVPN_LOCK_DIR:-}"
sh "$WORK/install.sh" install "$archive" "$prefix" || fail "install did not finish"

(
	trap '' INT TERM HUP
	"$prefix/sbin/engvpnd" set-password --data-dir "$prefix/data" <<EOF
$password
EOF
) || fail "panel password was not saved"

lan=""
type nvram >/dev/null 2>&1 && lan=$(nvram get lan_ipaddr 2>/dev/null)
echo
echo "EngVPN $version installed at $prefix."
echo "Open the panel: http://${lan:-192.168.50.1}:8790 — sign in with the password you chose"
echo "Paths: does not touch /jffs/addons/stealthsurf (:8800) or /jffs/addons/ssurf (:1131)"
