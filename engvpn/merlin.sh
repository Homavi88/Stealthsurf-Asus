#!/bin/sh
# Installs EngVPN on an Asuswrt-Merlin router over SSH:
#
#   curl -fsSL https://raw.githubusercontent.com/Homavi88/Stealthsurf-Asus/main/engvpn/merlin.sh | sh
#
# Reads the router feed, picks this router's package, checks SHA-256, runs the
# package install.sh, then asks for the panel password. Interactive install
# asks where to put files: JFFS (/jffs/addons/engvpn) or a mounted ext USB
# (/tmp/mnt/<name>/engvpn), showing required (≥ MIN_FREE_KB) and free space.
# ENGVPN_PREFIX skips the location prompt; ENGVPN_PASSWORD skips both prompts.
#
# Open reimplementation — does not ship StealthSurf proprietary binaries.
# Requires Entware Node.js for the panel runtime (opkg install node).
#
# Progress: prints [n/N] stages (RU). On failure: stage name + reason, exit 1.
# Non-interactive: ENGVPN_PASSWORD, ENGVPN_PREFIX, ENGVPN_LOCAL_PACKAGE, ENGVPN_FEED, …

set -u

# Entware first — firmware BusyBox wget cannot fetch HTTPS (GitHub releases).
export PATH="/opt/bin:/opt/sbin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

# Default feed: GitHub raw of this repo's feed (override for CDN).
FEED=${ENGVPN_FEED:-https://raw.githubusercontent.com/Homavi88/Stealthsurf-Asus/main/engvpn/feed/latest.json}
PACKAGE_PREFIX=${ENGVPN_PACKAGE_PREFIX:-https://github.com/Homavi88/Stealthsurf-Asus/releases/download/}
JFFS_PREFIX=/jffs/addons/engvpn
WORK=""
MIN_MEMORY_KB=230000
MIN_FREE_KB=20480
MIN_UPDATE_FREE_KB=10240
MIN_TMP_FREE_KB=32768

# Staged progress ([n/N]). install.sh continues from STAGE_NUM.
STAGE_TOTAL=9
STAGE_NUM=0
STAGE_NAME=""

stage() {
	STAGE_NUM=$((STAGE_NUM + 1))
	STAGE_NAME=$1
	echo "[$STAGE_NUM/$STAGE_TOTAL] $2"
}

fail() {
	if [ -n "${STAGE_NAME:-}" ]; then
		echo "Ошибка на этапе «$STAGE_NAME»: $*" >&2
	else
		echo "Ошибка: $*" >&2
	fi
	exit 1
}

trap '[ -n "$WORK" ] && rm -rf "$WORK"' EXIT
trap '{ type stty >/dev/null 2>&1 && stty echo </dev/tty; } 2>/dev/null; exit 1' INT TERM HUP

free_kb() {
	df -k "$1" 2>/dev/null | awk 'NR > 1 && NF >= 5 { value = $(NF - 2) } END { print value }'
}

# HTTPS downloader: prefer Entware curl. Must use -L — GitHub release URLs 302
# to release-assets.githubusercontent.com; without -L curl writes a 0-byte file
# and exits 0 (SHA-256 e3b0c442… = empty).
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
	# BusyBox-friendly size; prefer wc -c, fall back to ls.
	if bytes=$(wc -c <"$1" 2>/dev/null); then
		echo "$bytes" | tr -d ' '
		return 0
	fi
	# shellcheck disable=SC2012
	ls -ln "$1" 2>/dev/null | awk '{ print $5 }'
}

download_https() {
	# $1=url $2=out — returns 0 only when out is non-empty.
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

# Retry GitHub via public mirrors when direct fetch yields empty/HTTP error.
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
		echo "  → повтор через $_mirror" >&2
		if download_https "${_mirror}${_url}" "$_out"; then
			return 0
		fi
	done
	return 1
}

stage "Проверки" "Проверки окружения…"

# Off-router smoke / packaging hosts can skip Merlin and root checks.
if [ "${ENGVPN_SMOKE:-}" != 1 ]; then
	uid=$(awk '/^Uid:/ { print $3 }' /proc/self/status)
	[ "$uid" = 0 ] || fail "запустите скрипт от имени администратора роутера (root)"
	type nvram >/dev/null 2>&1 && [ -d /jffs ] || fail "это не прошивка ASUS с JFFS"
	uname -o 2>/dev/null | grep -qi merlin || [ -f /usr/sbin/helper.sh ] ||
		fail "нужен Asuswrt-Merlin (в стоковой ASUS нет пользовательских скриптов)"
fi

case "$(uname -m)" in
aarch64 | arm64) key=merlin-aarch64 ;;
armv7* | armv8l*) key=merlin-armv7 ;;
x86_64 | amd64)
	# Dev / smoke host
	key=merlin-x86_64
	;;
*) fail "CPU $(uname -m) пока не поддерживается: нужны ARM64, ARMv7 или x86_64 (dev)" ;;
esac

release=$(uname -r)
major=${release%%.*}
minor=${release#*.}
minor=${minor%%.*}
if [ "${ENGVPN_SMOKE:-}" != 1 ]; then
	if [ "${major:-0}" -lt 3 ] || { [ "$major" -eq 3 ] && [ "${minor:-0}" -lt 2 ]; }; then
		fail "ядро Linux $release слишком старое (нужно 4.1+)"
	fi
	memory=$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)
	[ "${memory:-0}" -ge "$MIN_MEMORY_KB" ] || fail "нужно не менее 256 МБ ОЗУ"
	tmp=$(free_kb /tmp)
	[ -z "$tmp" ] || [ "$tmp" -ge "$MIN_TMP_FREE_KB" ] ||
		fail "в /tmp свободно $((tmp / 1024)) МБ; нужно $((MIN_TMP_FREE_KB / 1024)) МБ"
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

# Effective free KB on filesystem for mount $1, counting leftover EngVPN files under $2.
space_kb() {
	avail=$(free_kb "$1")
	[ -n "$avail" ] || {
		echo 0
		return
	}
	echo $((avail + $(leftovers_kb "$2")))
}

mb_of() {
	echo $(($1 / 1024))
}

# Auto-pick: JFFS if enough space, else first USB with enough free space.
auto_prefix() {
	free=$(space_kb /jffs "$JFFS_PREFIX")
	if [ "$free" -ge "$MIN_FREE_KB" ]; then
		echo "$JFFS_PREFIX"
		return
	fi
	for mount in $(drives); do
		drive=$(space_kb "$mount" "$mount/engvpn")
		if [ "$drive" -ge "$MIN_FREE_KB" ]; then
			echo "$mount/engvpn"
			return
		fi
	done
	echo ""
}

# Interactive: list JFFS + USB candidates with required + free space; default JFFS when it fits.
# UI goes to /dev/tty so `prefix=$(prompt_prefix)` only captures the path.
prompt_prefix() {
	need_mb=$(mb_of "$MIN_FREE_KB")
	jffs_free=$(space_kb /jffs "$JFFS_PREFIX")
	{
		echo "Куда установить EngVPN?"
		echo "Нужно ≥${need_mb} МБ на выбранном носителе (новая установка)."
		echo "[1] Роутер (JFFS) — нужно ~${need_mb} МБ, свободно ~$(mb_of "$jffs_free") МБ — $JFFS_PREFIX"
	} >/dev/tty
	n=1
	default=1
	# paths keyed by index via eval (BusyBox ash has no arrays)
	eval "cand_path_1=\$JFFS_PREFIX"
	eval "cand_free_1=\$jffs_free"
	if [ "$jffs_free" -lt "$MIN_FREE_KB" ]; then
		default=0
	fi
	for mount in $(drives); do
		n=$((n + 1))
		name=${mount##*/}
		drive=$(space_kb "$mount" "$mount/engvpn")
		echo "[$n] Флешка $name — нужно ~${need_mb} МБ, свободно ~$(mb_of "$drive") МБ — $mount/engvpn" >/dev/tty
		eval "cand_path_$n=\$mount/engvpn"
		eval "cand_free_$n=\$drive"
		if [ "$default" -eq 0 ] && [ "$drive" -ge "$MIN_FREE_KB" ]; then
			default=$n
		fi
	done
	if [ "$default" -eq 0 ]; then
		default=1
	fi
	choice=""
	printf "Выбор [%s]: " "$default" >/dev/tty
	IFS= read -r choice </dev/tty || fail "не удалось прочитать выбор каталога"
	[ -n "$choice" ] || choice=$default
	case "$choice" in
	*[!0-9]* | "") fail "неверный выбор каталога установки: $choice" ;;
	esac
	if [ "$choice" -lt 1 ] || [ "$choice" -gt "$n" ]; then
		fail "неверный выбор каталога установки: $choice (1–$n)"
	fi
	eval "chosen=\$cand_path_$choice"
	eval "free=\$cand_free_$choice"
	if [ "${free:-0}" -lt "$MIN_FREE_KB" ]; then
		fail "в ${chosen%/engvpn} свободно $(mb_of "$free") МБ; нужно не меньше $(mb_of "$MIN_FREE_KB") МБ"
	fi
	echo "$chosen"
}

validate_prefix_space() {
	# $1 = prefix
	p=$1
	probe_dir=${p%/engvpn}
	while [ ! -d "$probe_dir" ] && [ -n "$probe_dir" ] && [ "$probe_dir" != "/" ]; do
		parent=${probe_dir%/*}
		[ "$parent" = "$probe_dir" ] && break
		probe_dir=$parent
	done
	free=$(space_kb "${probe_dir:-/}" "$p")
	need=$MIN_FREE_KB
	if installed "$p"; then
		need=$MIN_UPDATE_FREE_KB
	fi
	if [ "$free" -lt "$need" ]; then
		fail "в ${p%/engvpn} свободно $(mb_of "$free") МБ; нужно не меньше $(mb_of "$need") МБ"
	fi
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
		# Interactive location prompt when TTY is available and automation env is unset.
		# ENGVPN_PREFIX already skips this block; ENGVPN_PASSWORD marks non-interactive.
		can_prompt=0
		if [ -z "${ENGVPN_PASSWORD:-}" ]; then
			{ : </dev/tty; } 2>/dev/null && can_prompt=1
		fi
		if [ "$can_prompt" -eq 1 ]; then
			prefix=$(prompt_prefix) || exit 1
		else
			prefix=$(auto_prefix)
			free=$(space_kb /jffs "$JFFS_PREFIX")
			[ -n "$prefix" ] ||
				fail "на JFFS свободно $(mb_of "${free:-0}") МБ; нужно $(mb_of "$MIN_FREE_KB") МБ. Освободите место или подключите USB с ext4"
		fi
	fi
else
	case "$prefix" in
	/*) ;;
	*) fail "неверный каталог установки: $prefix" ;;
	esac
	validate_prefix_space "$prefix"
fi

# Panel password before any mutation (unless ENGVPN_PASSWORD is preset for automation).
password=${ENGVPN_PASSWORD:-}
if [ -z "$password" ]; then
	{ : </dev/tty; } 2>/dev/null ||
		fail "нет TTY для пароля панели: используйте ssh -t или задайте ENGVPN_PASSWORD"
	echo "Задайте пароль панели EngVPN (гости в LAN не попадут в панель)"
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
		printf "Пароль (8–128 символов): "
		password=""
		hidden_read password || fail "не удалось прочитать пароль"
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
			echo "Пароль должен быть 8–128 символов"
			continue
		fi
		if [ "$((printable))" -ne "$((bytes))" ] || c1_control; then
			echo "Пароль не должен содержать управляющие символы"
			continue
		fi
		printf "Ещё раз: "
		confirmation=""
		hidden_read confirmation || fail "не удалось прочитать пароль"
		echo
		case $confirmation in
		"$password") break ;;
		esac
		echo "Пароли не совпадают"
	done
fi

WORK=/tmp/engvpn-get.$$
rm -rf "$WORK"
mkdir -m 700 "$WORK" || fail "не удалось создать рабочий каталог в /tmp"

# Local package override for offline / smoke installs
if [ -n "${ENGVPN_LOCAL_PACKAGE:-}" ] && [ -f "$ENGVPN_LOCAL_PACKAGE" ]; then
	stage "Загрузка" "Локальный пакет…"
	archive=$ENGVPN_LOCAL_PACKAGE
	version=${ENGVPN_LOCAL_VERSION:-local}
	echo "  → $archive"
	stage "Проверка" "Проверка (локальный пакет — SHA-256 ленты не применяется)…"
else
	stage "Загрузка" "Загрузка ленты и пакета…"
	find_https_fetch >/dev/null 2>&1 ||
		fail "нужен curl с HTTPS (Entware: opkg update && opkg install curl)"
	feed_tmp=$WORK/latest.json
	download_https_mirrored "$FEED" "$feed_tmp" || fail "не удалось скачать ленту $FEED"
	feed=$(cat "$feed_tmp")
	feed_bytes=$(file_bytes "$feed_tmp")
	[ -n "$feed" ] || fail "лента пустая ($FEED)"
	# BusyBox/entware: flexible whitespace; minified or pretty; quoted/bare values.
	# Brace-depth so fields from the next arch block cannot leak in.
	field() {
		printf '%s\n' "$feed" | awk -v arch="$key" -v name="$1" '
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
		printf '%s\n' "$feed" | awk '
			match($0, /"version"[[:space:]]*:[[:space:]]*"/) {
				s = substr($0, RSTART + RLENGTH)
				sub(/".*/, "", s)
				print s
				exit
			}'
	}
	feed_diag() {
		echo "  → лента: $FEED (${feed_bytes:-?} байт)" >&2
		echo "  → первые строки ленты:" >&2
		printf '%s\n' "$feed" | head -n 8 | sed 's/^/    /' >&2
		echo "  → version=[${version:-}] keys=[$(printf '%s\n' "$feed" | sed -n 's/^[[:space:]]*"\(merlin-[^"]*\)".*/\1/p' | tr '\n' ' ')]" >&2
		echo "  → url=[${url:-}] sha256=[${sha256:-}]" >&2
	}
	# Suspiciously small: real latest.json is ~1 KiB; HTML/error pages are often tiny or huge.
	if [ -n "$feed_bytes" ] && [ "$feed_bytes" -lt 100 ]; then
		feed_diag
		fail "лента слишком маленькая (${feed_bytes} байт) — проверьте $FEED"
	fi
	version=$(feed_version)
	url=$(field url)
	sha256=$(field sha256)
	expect_size=$(field size)
	if [ -z "$version" ] || [ -z "$url" ] || [ -z "$sha256" ]; then
		feed_diag
		fail "в ленте нет пакета для $key (нужны version+url+sha256; смотрите диагностику выше)"
	fi
	# Allow GitHub release URLs or configured prefix
	case "$url" in
	https://github.com/* | https://raw.githubusercontent.com/* | "$PACKAGE_PREFIX"* | http://127.0.0.1/* | http://localhost/*) ;;
	*)
		# Also allow file:// for smoke
		case "$url" in
		file://*) ;;
		*) fail "URL пакета должен быть с разрешённого HTTPS-хоста (получено $url)" ;;
		esac
		;;
	esac
	echo "  → EngVPN $version ($key)"
	echo "  → $url"
	archive=$WORK/engvpn.tar.gz
	case "$url" in
	file://*)
		src=${url#file://}
		cp -f "$src" "$archive" || fail "не удалось скопировать $src"
		;;
	*)
		download_https_mirrored "$url" "$archive" ||
			fail "не удалось скачать пакет (HTTP/пусто; проверьте curl -fL и доступ к GitHub)"
		;;
	esac
	got_bytes=$(file_bytes "$archive")
	[ -n "$got_bytes" ] && [ "$got_bytes" -gt 0 ] ||
		fail "пакет пустой (0 байт) после загрузки — нужен curl с -L (редирект GitHub)"
	echo "  → скачано ${got_bytes} байт"
	if [ -n "$expect_size" ] && [ "$expect_size" != "0" ] && [ "$got_bytes" -ne "$expect_size" ]; then
		echo "  → предупреждение: размер ленты $expect_size, получено $got_bytes" >&2
	fi

	stage "Проверка" "Проверка SHA-256 и подписи…"
	if type sha256sum >/dev/null 2>&1; then
		actual=$(sha256sum "$archive" | awk '{ print $1 }')
	else
		actual=$(openssl dgst -sha256 -r "$archive" | awk '{ print $1 }')
	fi
	[ "$actual" = "$sha256" ] ||
		fail "контрольная сумма пакета не совпадает с лентой (ожидалось $sha256, получено $actual, размер $got_bytes)"
	# Minisign (optional but preferred when feed publishes .minisig)
	sig_url=$(field minisig)
	[ -z "$sig_url" ] && sig_url="${url}.minisig"
	sig=$WORK/engvpn.tar.gz.minisig
	case "$sig_url" in
	file://*) [ -f "${sig_url#file://}" ] && cp -f "${sig_url#file://}" "$sig" || true ;;
	https://* | http://127.0.0.1/* | http://localhost/*)
		download_https "$sig_url" "$sig" 2>/dev/null || true
		;;
	esac
	if [ -f "$sig" ] && [ -s "$sig" ]; then
		pub_url=${ENGVPN_MINISIGN_PUB:-https://raw.githubusercontent.com/Homavi88/Stealthsurf-Asus/main/engvpn/keys/engvpn.minisign.pub}
		pub=$WORK/engvpn.minisign.pub
		download_https "$pub_url" "$pub" 2>/dev/null || true
		if [ -f "$pub" ] && [ -s "$pub" ] && command -v minisign >/dev/null 2>&1; then
			minisign -Vm "$archive" -x "$sig" -p "$pub" || fail "проверка Minisign не прошла"
			echo "  → Minisign OK"
		elif [ -f "$pub" ] && [ -s "$pub" ] && command -v node >/dev/null 2>&1; then
			echo "  → подпись Minisign есть (полная проверка Node — после установки); SHA-256 уже сверен"
		else
			echo "  → .minisig есть, но верификатор недоступен; SHA-256 уже сверен"
		fi
	fi
fi

tar -xzOf "$archive" ./share/engvpn/install.sh >"$WORK/install.sh" ||
	fail "в пакете нет install.sh"
chmod +x "$WORK/install.sh"

# Hint: Node is required at runtime
if ! { [ -x /opt/bin/node ] || command -v node >/dev/null 2>&1; }; then
	echo "Примечание: панели нужен Node.js (Entware: opkg update && opkg install node)"
fi

trap ':' INT TERM HUP
# Pass smoke / progress env through; defer start until password is saved.
export ENGVPN_SMOKE="${ENGVPN_SMOKE:-}"
export ENGVPN_SCRIPTS="${ENGVPN_SCRIPTS:-}"
export ENGVPN_LOCK_DIR="${ENGVPN_LOCK_DIR:-}"
export ENGVPN_DEFER_START=1
export ENGVPN_STAGE_TOTAL="$STAGE_TOTAL"
export ENGVPN_STAGE_NUM="$STAGE_NUM"
# install.sh prints its own staged errors; do not wrap with a second fail().
if ! sh "$WORK/install.sh" install "$archive" "$prefix"; then
	exit 1
fi
# install.sh printed stages 4–7 (unpack…hooks); child cannot export STAGE_NUM back.
STAGE_NUM=7

stage "Пароль" "Сохранение пароля панели…"
(
	trap '' INT TERM HUP
	"$prefix/sbin/engvpnd" set-password --data-dir "$prefix/data" <<EOF
$password
EOF
) || fail "пароль панели не сохранён"

stage "Запуск" "Запуск сервиса…"
export ENGVPN_SMOKE="${ENGVPN_SMOKE:-}"
export ENGVPN_LOCK_DIR="${ENGVPN_LOCK_DIR:-}"
export ENGVPN_SCRIPTS="${ENGVPN_SCRIPTS:-}"
"$prefix/share/engvpn/service.sh" restart || fail "сервис EngVPN не запустился"

lan=""
type nvram >/dev/null 2>&1 && lan=$(nvram get lan_ipaddr 2>/dev/null)
lan=${lan:-192.168.50.1}
port=${ENGVPN_PORT:-8790}
echo
echo "EngVPN $version установлен в $prefix."
echo
echo "Откройте панель:"
echo "http://${lan}:${port}"
echo
echo "Адрес: $lan"
echo "Порт:  $port"
echo "Войдите с выбранным паролем."
echo
echo "CLI:"
echo "  engvpnd"
echo "  полный путь: $prefix/sbin/engvpnd"
if [ -L /opt/bin/engvpnd ] || [ -x /opt/bin/engvpnd ]; then
	echo "  в PATH:     /opt/bin/engvpnd"
elif [ "${ENGVPN_SMOKE:-}" = 1 ] && [ -n "${ENGVPN_BIN_DIR:-}" ] &&
	{ [ -L "$ENGVPN_BIN_DIR/engvpnd" ] || [ -x "$ENGVPN_BIN_DIR/engvpnd" ]; }; then
	echo "  в PATH:     $ENGVPN_BIN_DIR/engvpnd"
fi
echo
echo "Пути: не трогает /jffs/addons/stealthsurf (:8800) и /jffs/addons/ssurf (:1131)"
