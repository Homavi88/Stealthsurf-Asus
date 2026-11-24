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

# Must follow redirects (-L): GitHub release URLs 302 to CDN; without -L
# curl writes 0 bytes and exits 0 (empty-file SHA e3b0c442…).
find_https_fetch() {
	if [ -x /opt/bin/curl ]; then
		echo /opt/bin/curl
		return 0
	fi
	if [ -x /usr/sbin/curl ]; then
		echo /usr/sbin/curl
		return 0
	fi
	if command -v curl >/dev/null 2>&1; then
		command -v curl
		return 0
	fi
	if [ -x /opt/bin/wget ]; then
		echo /opt/bin/wget
		return 0
	fi
	return 1
}

file_bytes() {
	if bytes=$(wc -c <"$1" 2>/dev/null); then
		echo "$bytes" | tr -d ' '
		return 0
	fi
	# shellcheck disable=SC2012
	ls -ln "$1" 2>/dev/null | awk '{ print $5 }'
}

download_https() {
	_url=$1
	_out=$2
	_bin=$(find_https_fetch) || return 1
	rm -f "$_out"
	case "$_bin" in
	*curl)
		"$_bin" -fL --connect-timeout 30 --retry 3 --retry-delay 2 -o "$_out" "$_url" || {
			rm -f "$_out"
			return 1
		}
		;;
	*wget)
		# GNU/Entware wget follows redirects; non-zero on HTTP errors (may leave 0-byte file).
		"$_bin" -q --timeout=30 --tries=3 -O "$_out" "$_url" || {
			rm -f "$_out"
			return 1
		}
		;;
	*)
		return 1
		;;
	esac
	if [ -f "$_out" ] && [ -s "$_out" ]; then
		return 0
	fi
	rm -f "$_out"
	return 1
}

download_https_mirrored() {
	_url=$1
	_out=$2
	if download_https "$_url" "$_out"; then
		return 0
	fi
	case "$_url" in
	https://github.com/* | https://raw.githubusercontent.com/* | https://release-assets.githubusercontent.com/*) ;;
	*)
		return 1
		;;
	esac
	for _mirror in \
		'https://ghfast.top/' \
		'https://gh-proxy.com/' \
		'https://cdn.gh-proxy.org/' \
		'https://gitproxy.click/'; do
		echo "update: retry via $_mirror" >&2
		if download_https "${_mirror}${_url}" "$_out"; then
			return 0
		fi
	done
	return 1
}

fetch_feed() {
	tmp=/tmp/engvpn-feed.$$.json
	download_https_mirrored "$FEED" "$tmp" || fail "could not fetch $FEED"
	bytes=$(file_bytes "$tmp")
	if [ -n "$bytes" ] && [ "$bytes" -lt 100 ]; then
		echo "update: feed too small (${bytes} bytes): $FEED" >&2
		head -n 8 "$tmp" | sed 's/^/  /' >&2
		rm -f "$tmp"
		fail "feed too small (${bytes} bytes)"
	fi
	cat "$tmp"
	rm -f "$tmp"
}

# Flexible whitespace; minified or pretty; quoted/bare; brace-depth (no cross-arch leak).
field() {
	feed=$1
	key=$2
	name=$3
	printf '%s\n' "$feed" | awk -v arch="$key" -v name="$name" '
		function extract_from(s, name,    value) {
			if (!match(s, "\"" name "\"[[:space:]]*:")) return 0
			value = substr(s, RSTART + RLENGTH)
			sub(/^[[:space:]]+/, "", value)
			if (substr(value, 1, 1) == "\"") {
				value = substr(value, 2)
				if (match(value, /"/)) value = substr(value, 1, RSTART - 1)
				else value = ""
			} else {
				sub(/[[:space:],}].*/, "", value)
			}
			print value
			return 1
		}
		function scan(s, name,    i, c, n, chunk) {
			n = length(s)
			i = 1
			while (i <= n) {
				c = substr(s, i, 1)
				if (c == "{") { depth++; i++; continue }
				if (c == "}") {
					depth--
					if (depth <= 0) return 0
					i++
					continue
				}
				if (c == "\"") {
					chunk = substr(s, i)
					if (match(chunk, "^\"" name "\"[[:space:]]*:")) {
						if (extract_from(chunk, name)) return 1
					}
					i++
					while (i <= n) {
						c = substr(s, i, 1)
						if (c == "\\") { i += 2; continue }
						if (c == "\"") { i++; break }
						i++
					}
					continue
				}
				i++
			}
			return 0
		}
		BEGIN { depth = 0; inside = 0 }
		{
			if (!inside) {
				if (match($0, "\"" arch "\"[[:space:]]*:[[:space:]]*\\{")) {
					inside = 1
					depth = 1
					rest = substr($0, RSTART + RLENGTH)
					if (scan(rest, name)) exit
				}
				next
			}
			if (scan($0, name)) exit
			if (depth <= 0) exit
		}'
}

feed_version() {
	printf '%s\n' "$1" | awk '
		match($0, /"version"[[:space:]]*:[[:space:]]*"/) {
			s = substr($0, RSTART + RLENGTH)
			sub(/".*/, "", s)
			print s
			exit
		}'
}

feed_diag() {
	feed=$1
	key=$2
	ver=$3
	url=$4
	sha=$5
	echo "update: feed=$FEED" >&2
	echo "update: first lines:" >&2
	printf '%s\n' "$feed" | head -n 8 | sed 's/^/  /' >&2
	echo "update: version=[$ver] keys=[$(printf '%s\n' "$feed" | sed -n 's/^[[:space:]]*"\(merlin-[^"]*\)".*/\1/p' | tr '\n' ' ')]" >&2
	echo "update: url=[$url] sha256=[$sha] arch=$key" >&2
}

# Canonical GitHub release asset for this arch (never a build-host path).
github_release_url() {
	_ver=$1
	_arch=$2
	echo "${PACKAGE_PREFIX}engvpn-${_ver}/engvpn_${_ver}_${_arch}.tar.gz"
}

# Allow file:// / absolute paths only for smoke or under the install prefix.
# Foreign build paths (/agent/repos/…) → rewrite to GitHub release URL.
resolve_package_url() {
	_raw=$1
	_ver=$2
	_arch=$3
	_src=""
	case "$_raw" in
	https://github.com/*/releases/download/* | https://raw.githubusercontent.com/* | "$PACKAGE_PREFIX"* | http://127.0.0.1/* | http://localhost/*)
		echo "$_raw"
		return 0
		;;
	file://*)
		_src=${_raw#file://}
		;;
	/*)
		_src=$_raw
		;;
	"")
		echo "update: empty package url — using GitHub release" >&2
		github_release_url "$_ver" "$_arch"
		return 0
		;;
	*)
		echo "update: refusing URL $_raw" >&2
		return 1
		;;
	esac
	# Explicit smoke/local allow first (dev hosts often live under /agent/…).
	if [ -n "${ENGVPN_SMOKE:-}${ENGVPN_ALLOW_LOCAL:-}" ] && [ -f "$_src" ]; then
		echo "file://$_src"
		return 0
	fi
	case "$_src" in
	"$PREFIX"/* | "$PREFIX")
		if [ -f "$_src" ]; then
			echo "file://$_src"
			return 0
		fi
		;;
	esac
	# Absolute / file:// paths outside the install root are never used for remote updates.
	echo "update: rejecting local path $_src — using GitHub release" >&2
	github_release_url "$_ver" "$_arch"
	return 0
}

fetch_package() {
	_url=$1
	_archive=$2
	case "$_url" in
	file://*)
		cp -f "${_url#file://}" "$_archive" || return 1
		;;
	*)
		download_https_mirrored "$_url" "$_archive" || return 1
		;;
	esac
	return 0
}

cmd_check() {
	feed=$(fetch_feed)
	ver=$(feed_version "$feed")
	cur=$(installed_version)
	key=$(arch_key)
	url=$(field "$feed" "$key" url)
	resolved=$(resolve_package_url "$url" "$ver" "$key") || resolved=""
	echo "installed=$cur"
	echo "current=$cur"
	echo "feed=$ver"
	echo "arch=$key"
	echo "url=$resolved"
	if [ -n "$url" ] && [ "$url" != "$resolved" ]; then
		echo "feed_url=$url"
	fi
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
	ver=$(feed_version "$feed")
	url=$(field "$feed" "$key" url)
	sha256=$(field "$feed" "$key" sha256)
	if [ -z "$ver" ] || [ -z "$sha256" ]; then
		feed_diag "$feed" "$key" "$ver" "$url" "$sha256"
		fail "incomplete feed for $key (need version+sha256; see diagnostics above)"
	fi
	url=$(resolve_package_url "$url" "$ver" "$key") || {
		feed_diag "$feed" "$key" "$ver" "$url" "$sha256"
		fail "could not resolve package URL for $key"
	}
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
	echo "update: fetching $url"
	fetch_package "$url" "$archive" ||
		fail "download/copy failed (HTTP/empty or missing file; need curl -fL for GitHub redirects)"
	got_bytes=$(file_bytes "$archive")
	[ -n "$got_bytes" ] && [ "$got_bytes" -gt 0 ] ||
		fail "downloaded package is empty (0 bytes)"
	echo "update: downloaded ${got_bytes} bytes"
	expect_size=$(field "$feed" "$key" size)
	if [ -n "$expect_size" ] && [ "$expect_size" != "0" ] && [ "$got_bytes" -ne "$expect_size" ]; then
		echo "update: warning: feed size $expect_size, got $got_bytes" >&2
	fi
	if type sha256sum >/dev/null 2>&1; then
		actual=$(sha256sum "$archive" | awk '{ print $1 }')
	else
		actual=$(openssl dgst -sha256 -r "$archive" | awk '{ print $1 }')
	fi
	[ "$actual" = "$sha256" ] || fail "checksum mismatch (expected $sha256 got $actual size $got_bytes)"
	# Minisign verify when .minisig is published alongside the archive
	sig_url=$(field "$feed" "$key" minisig)
	case "$sig_url" in
	file://* | /*)
		# Never require a build-host minisig for remote updates
		sig_url=""
		;;
	esac
	[ -z "$sig_url" ] && case "$url" in https://*) sig_url="${url}.minisig" ;; esac
	sig=$WORK/engvpn.tar.gz.minisig
	pub=$SHARE/engvpn.minisign.pub
	verify=$SHARE/verify-minisign.mjs
	sig_ok=0
	case "$sig_url" in
	file://*)
		[ -n "${ENGVPN_SMOKE:-}${ENGVPN_ALLOW_LOCAL:-}" ] &&
			[ -f "${sig_url#file://}" ] && cp -f "${sig_url#file://}" "$sig" || true
		;;
	https://* | http://127.0.0.1/* | http://localhost/*)
		download_https "$sig_url" "$sig" 2>/dev/null || true
		;;
	esac
	if [ -f "$sig" ] && [ -f "$pub" ]; then
		if [ -f "$verify" ] && command -v node >/dev/null 2>&1; then
			node "$verify" "$archive" "$sig" "$pub" && sig_ok=1
		elif command -v minisign >/dev/null 2>&1; then
			minisign -Vm "$archive" -x "$sig" -p "$pub" && sig_ok=1
		fi
		[ "$sig_ok" = 1 ] || fail "minisign verification failed"
		echo "update: minisign ok"
	else
		echo "update: no minisig (SHA-256 only)" >&2
	fi
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
