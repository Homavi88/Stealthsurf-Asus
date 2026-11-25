#!/bin/sh
# Download EngVPN engine cores + geo DBs after install/upgrade (no Node).
#
#   sh download-cores.sh [--data-dir DIR] [--prefix DIR] [--only ID]
#
# ID: all (default) | xray | ferrum | sing-box | mihomo | geo
# Soft-fail: exit 0 even if some cores fail (panel can retry).
# ENGVPN_SKIP_CORES=1 skips entirely. Smoke stays offline unless ENGVPN_FETCH_CORES=1.
set -u

PATH="/opt/bin:/opt/sbin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
export PATH
UA=${ENGVPN_UA:-engvpn}
GEO_BASE=${ENGVPN_GEO_BASE:-https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download}
SHARE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PREFIX_DEFAULT=$(CDPATH= cd -- "$SHARE/../.." && pwd)
DATA_DIR=""
PREFIX=""
ONLY=all

while [ $# -gt 0 ]; do
	case "$1" in
	--data-dir)
		DATA_DIR=${2:-}
		shift 2
		;;
	--prefix)
		PREFIX=${2:-}
		shift 2
		;;
	--only)
		ONLY=${2:-all}
		shift 2
		;;
	*)
		shift
		;;
	esac
done

[ -n "$PREFIX" ] || PREFIX=${ENGVPN_PREFIX:-$PREFIX_DEFAULT}
[ -n "$DATA_DIR" ] || DATA_DIR=${ENGVPN_DATA_DIR:-$PREFIX/data}
CORE_DIR=$DATA_DIR/cores
GEO_DIR=$DATA_DIR/geo
TMP_DIR=$DATA_DIR/.download-tmp
FAILED=0

case "${ENGVPN_SKIP_CORES:-}" in
1 | yes | YES | y | Y)
	echo "download-cores: skipped (ENGVPN_SKIP_CORES=1)"
	exit 0
	;;
esac
if [ "${ENGVPN_SMOKE:-}" = 1 ] && [ "${ENGVPN_FETCH_CORES:-}" != 1 ]; then
	echo "download-cores: skipped (smoke; set ENGVPN_FETCH_CORES=1 to force)"
	exit 0
fi

mkdir -p "$CORE_DIR" "$GEO_DIR" "$TMP_DIR" 2>/dev/null || true

fmt_bytes() {
	awk -v b="${1:-0}" 'BEGIN {
		if (b < 1024) printf "%d Б", b
		else if (b < 1048576) printf "%.1f КБ", b / 1024
		else printf "%.1f МБ", b / 1048576
	}'
}

file_bytes() {
	if bytes=$(wc -c <"$1" 2>/dev/null); then
		echo "$bytes" | tr -d ' '
		return 0
	fi
	# shellcheck disable=SC2012
	ls -ln "$1" 2>/dev/null | awk '{ print $5 }'
}

find_https() {
	if [ -x /opt/bin/curl ]; then
		echo /opt/bin/curl
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

download_one() {
	_url=$1
	_out=$2
	_bin=$(find_https) || return 1
	rm -f "$_out"
	case "$_bin" in
	*curl)
		"$_bin" -fsSL --connect-timeout 30 --retry 3 --retry-delay 2 -A "$UA" -o "$_out" "$_url" || {
			rm -f "$_out"
			return 1
		}
		;;
	*wget)
		"$_bin" -q --timeout=30 --tries=3 -U "$UA" -O "$_out" "$_url" || {
			rm -f "$_out"
			return 1
		}
		;;
	*)
		return 1
		;;
	esac
	[ -f "$_out" ] && [ -s "$_out" ]
}

download_mirrored() {
	_url=$1
	_out=$2
	if download_one "$_url" "$_out"; then
		return 0
	fi
	case "$_url" in
	https://github.com/* | https://raw.githubusercontent.com/* | https://api.github.com/*) ;;
	*)
		return 1
		;;
	esac
	for _mirror in \
		'https://ghfast.top/' \
		'https://gh-proxy.com/' \
		'https://cdn.gh-proxy.org/' \
		'https://gitproxy.click/'; do
		echo "  → повтор через $_mirror" >&2
		if download_one "${_mirror}${_url}" "$_out"; then
			return 0
		fi
	done
	return 1
}

host_arch() {
	case "$(uname -m)" in
	aarch64 | arm64) echo arm64 ;;
	armv7* | armv8l* | arm) echo arm ;;
	x86_64 | amd64) echo amd64 ;;
	*) echo amd64 ;;
	esac
}

github_tag() {
	_repo=$1
	_json=$TMP_DIR/rel-${_repo##*/}.json
	if ! download_mirrored "https://api.github.com/repos/${_repo}/releases/latest" "$_json"; then
		return 1
	fi
	# Prefer python for nested JSON; sed fallback for tag_name only.
	if command -v python3 >/dev/null 2>&1; then
		python3 - "$_json" <<'PY'
import json,sys
print(json.load(open(sys.argv[1])).get("tag_name",""))
PY
		return 0
	fi
	sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$_json" | head -1
}

# Extract zip member → dest (Merlin often lacks unzip; try several tools).
extract_zip_member() {
	_zip=$1
	_member=$2
	_dest=$3
	_dir=$(dirname "$_dest")
	mkdir -p "$_dir"
	if command -v unzip >/dev/null 2>&1; then
		if unzip -o -j "$_zip" "$_member" -d "$_dir" >/dev/null 2>&1; then
			if [ -f "$_dir/$_member" ] && [ "$_dir/$_member" != "$_dest" ]; then
				mv -f "$_dir/$_member" "$_dest"
			fi
			[ -f "$_dest" ] && return 0
		fi
	fi
	if command -v busybox >/dev/null 2>&1 && busybox unzip -h >/dev/null 2>&1; then
		if busybox unzip -o -j "$_zip" "$_member" -d "$_dir" >/dev/null 2>&1; then
			if [ -f "$_dir/$_member" ] && [ "$_dir/$_member" != "$_dest" ]; then
				mv -f "$_dir/$_member" "$_dest"
			fi
			[ -f "$_dest" ] && return 0
		fi
	fi
	if command -v python3 >/dev/null 2>&1; then
		python3 - "$_zip" "$_member" "$_dest" <<'PY'
import sys, zipfile
z, member, dest = sys.argv[1], sys.argv[2], sys.argv[3]
with zipfile.ZipFile(z) as zf:
    for name in zf.namelist():
        base = name.rsplit("/", 1)[-1]
        if base == member or name == member:
            with zf.open(name) as src, open(dest, "wb") as out:
                out.write(src.read())
            raise SystemExit(0)
raise SystemExit("missing member")
PY
		[ -f "$_dest" ] && return 0
	fi
	return 1
}

find_named() {
	_root=$1
	_name=$2
	_depth=${3:-0}
	[ "$_depth" -gt 4 ] && return 1
	for _e in "$_root"/* "$_root"/.[!.]*; do
		[ -e "$_e" ] || continue
		_base=${_e##*/}
		if [ -d "$_e" ]; then
			_hit=$(find_named "$_e" "$_name" $((_depth + 1))) && {
				echo "$_hit"
				return 0
			}
		elif [ "$_base" = "$_name" ]; then
			echo "$_e"
			return 0
		fi
	done
	return 1
}

install_mode() {
	chmod 755 "$1" 2>/dev/null || true
}

probe_ok() {
	_bin=$1
	_id=$2
	[ -x "$_bin" ] || return 1
	_out=""
	if [ "$_id" = mihomo ]; then
		_out=$("$_bin" -v 2>&1 || true)
	else
		_out=$("$_bin" version 2>&1 || true)
	fi
	case "$_out" in
	*libresolv.so* | *"cannot open shared object"* | *"error while loading shared libraries"* | *"Exec format error"*)
		return 1
		;;
	esac
	return 0
}

ARCH=$(host_arch)
case "$ARCH" in
arm64)
	XRAY_ASSET=Xray-linux-arm64-v8a.zip
	SING_ARCH=arm64
	MIHOMO_ARCH=arm64
	;;
arm)
	XRAY_ASSET=Xray-linux-arm32-v7a.zip
	SING_ARCH=armv7
	MIHOMO_ARCH=armv7
	;;
*)
	XRAY_ASSET=Xray-linux-64.zip
	SING_ARCH=amd64
	MIHOMO_ARCH=amd64
	;;
esac

download_xrayish() {
	# $1 = dest name (xray|ferrum)
	_dest_name=$1
	_dest=$CORE_DIR/$_dest_name
	_tmp=$TMP_DIR/$_dest_name-$XRAY_ASSET
	echo "  → ядро $_dest_name (Xray-core)…"
	_url="https://github.com/XTLS/Xray-core/releases/latest/download/$XRAY_ASSET"
	if ! download_mirrored "$_url" "$_tmp"; then
		echo "  → $_dest_name: ошибка — скачивание"
		FAILED=$((FAILED + 1))
		return 1
	fi
	rm -f "$_dest"
	if ! extract_zip_member "$_tmp" xray "$_dest"; then
		echo "  → $_dest_name: ошибка — распаковка (нужен unzip или python3)"
		FAILED=$((FAILED + 1))
		rm -f "$_tmp"
		return 1
	fi
	rm -f "$_tmp"
	install_mode "$_dest"
	_sz=$(file_bytes "$_dest")
	echo "  → $_dest_name: готово ($(fmt_bytes "${_sz:-0}"))"
	return 0
}

download_singbox() {
	_dest=$CORE_DIR/sing-box
	echo "  → ядро sing-box…"
	_tag=$(github_tag SagerNet/sing-box) || _tag=""
	[ -n "$_tag" ] || {
		echo "  → sing-box: ошибка — не удалось узнать релиз"
		FAILED=$((FAILED + 1))
		return 1
	}
	_ver=${_tag#v}
	# Prefer musl (Merlin often lacks libresolv.so.2), then plain, then glibc.
	_ok=0
	for _kind in musl plain glibc; do
		case "$_kind" in
		musl) _asset="sing-box-${_ver}-linux-${SING_ARCH}-musl.tar.gz" ;;
		plain) _asset="sing-box-${_ver}-linux-${SING_ARCH}.tar.gz" ;;
		glibc) _asset="sing-box-${_ver}-linux-${SING_ARCH}-glibc.tar.gz" ;;
		esac
		_tmp=$TMP_DIR/$_asset
		_url="https://github.com/SagerNet/sing-box/releases/download/${_tag}/${_asset}"
		echo "  → sing-box: пробую $_asset"
		if ! download_mirrored "$_url" "$_tmp"; then
			continue
		fi
		rm -rf "$TMP_DIR/sing-extract"
		mkdir -p "$TMP_DIR/sing-extract"
		if ! tar -xzf "$_tmp" -C "$TMP_DIR/sing-extract" 2>/dev/null; then
			rm -f "$_tmp"
			continue
		fi
		_found=$(find_named "$TMP_DIR/sing-extract" sing-box) || _found=""
		rm -f "$_tmp"
		if [ -z "$_found" ] || [ ! -f "$_found" ]; then
			rm -rf "$TMP_DIR/sing-extract"
			continue
		fi
		rm -f "$_dest"
		mv -f "$_found" "$_dest"
		rm -rf "$TMP_DIR/sing-extract"
		install_mode "$_dest"
		if probe_ok "$_dest" sing-box; then
			_ok=1
			break
		fi
		echo "  → sing-box: $_asset не запускается (loader), следующий…"
		rm -f "$_dest"
	done
	if [ "$_ok" -eq 1 ]; then
		_sz=$(file_bytes "$_dest")
		echo "  → sing-box: готово $_tag ($(fmt_bytes "${_sz:-0}"))"
		return 0
	fi
	echo "  → sing-box: ошибка — нет совместимого бинарника"
	FAILED=$((FAILED + 1))
	return 1
}

download_mihomo() {
	_dest=$CORE_DIR/mihomo
	echo "  → ядро mihomo…"
	_tag=$(github_tag MetaCubeX/mihomo) || _tag=""
	[ -n "$_tag" ] || {
		echo "  → mihomo: ошибка — не удалось узнать релиз"
		FAILED=$((FAILED + 1))
		return 1
	}
	_asset="mihomo-linux-${MIHOMO_ARCH}-${_tag}.gz"
	_tmp=$TMP_DIR/$_asset
	_url="https://github.com/MetaCubeX/mihomo/releases/download/${_tag}/${_asset}"
	if ! download_mirrored "$_url" "$_tmp"; then
		# Fallback: compatible build without tag in name
		_asset="mihomo-linux-${MIHOMO_ARCH}-compatible.gz"
		_tmp=$TMP_DIR/$_asset
		_url="https://github.com/MetaCubeX/mihomo/releases/download/${_tag}/${_asset}"
		if ! download_mirrored "$_url" "$_tmp"; then
			echo "  → mihomo: ошибка — скачивание"
			FAILED=$((FAILED + 1))
			return 1
		fi
	fi
	rm -f "$_dest"
	if command -v gzip >/dev/null 2>&1; then
		gzip -dc "$_tmp" >"$_dest" || {
			rm -f "$_tmp" "$_dest"
			echo "  → mihomo: ошибка — gunzip"
			FAILED=$((FAILED + 1))
			return 1
		}
	elif command -v gunzip >/dev/null 2>&1; then
		gunzip -c "$_tmp" >"$_dest" || {
			rm -f "$_tmp" "$_dest"
			echo "  → mihomo: ошибка — gunzip"
			FAILED=$((FAILED + 1))
			return 1
		}
	else
		# busybox gzip -d -c
		gzip -d -c "$_tmp" >"$_dest" 2>/dev/null || {
			rm -f "$_tmp" "$_dest"
			echo "  → mihomo: ошибка — нет gzip"
			FAILED=$((FAILED + 1))
			return 1
		}
	fi
	rm -f "$_tmp"
	install_mode "$_dest"
	_sz=$(file_bytes "$_dest")
	echo "  → mihomo: готово $_tag ($(fmt_bytes "${_sz:-0}"))"
	return 0
}

download_geo() {
	_ok=0
	for _name in geosite.dat geoip.dat; do
		echo "  → geo $_name…"
		_dest=$GEO_DIR/$_name
		_tmp=$TMP_DIR/$_name
		if download_mirrored "$GEO_BASE/$_name" "$_tmp"; then
			mv -f "$_tmp" "$_dest"
			_sz=$(file_bytes "$_dest")
			echo "  → geo $_name: $(fmt_bytes "${_sz:-0}")"
			_ok=$((_ok + 1))
		else
			echo "  → geo $_name: ошибка"
			FAILED=$((FAILED + 1))
			rm -f "$_tmp"
		fi
	done
	[ "$_ok" -eq 2 ] && echo "download-cores: geo ok"
	return 0
}

echo "download-cores: data=$DATA_DIR arch=$ARCH only=$ONLY"

case "$ONLY" in
all | "")
	download_xrayish xray || true
	download_xrayish ferrum || true
	download_singbox || true
	download_mihomo || true
	download_geo || true
	;;
xray) download_xrayish xray || true ;;
ferrum) download_xrayish ferrum || true ;;
sing-box) download_singbox || true ;;
mihomo) download_mihomo || true ;;
geo) download_geo || true ;;
*)
	echo "download-cores: unknown --only $ONLY" >&2
	;;
esac

PRESENT=0
for _id in xray ferrum sing-box mihomo; do
	[ -f "$CORE_DIR/$_id" ] && [ -s "$CORE_DIR/$_id" ] && PRESENT=$((PRESENT + 1))
done
echo "download-cores: cores present $PRESENT/4${FAILED:+ (failures=$FAILED)}"
rm -rf "$TMP_DIR" 2>/dev/null || true
exit 0
