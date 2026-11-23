#!/bin/sh
# Installs EngVPN on an Asuswrt-Merlin router over SSH:
#
#   curl -fsSL https://raw.githubusercontent.com/Homavi88/Stealthsurf-Asus/main/engvpn/merlin.sh | sh
#
# Reads the router feed, picks this router's package, checks SHA-256, runs the
# package install.sh, then asks for the panel password. Interactive install
# asks where to put files: JFFS (/jffs/addons/engvpn) or a mounted ext USB
# (/tmp/mnt/<name>/engvpn), showing free space for each option.
# ENGVPN_PREFIX skips the location prompt; ENGVPN_PASSWORD skips both prompts.
#
# Open reimplementation — does not ship StealthSurf proprietary binaries.
# Requires Entware Node.js for the panel runtime (opkg install node).
#
# Progress: prints [n/N] stages (RU). On failure: stage name + reason, exit 1.
# Non-interactive: ENGVPN_PASSWORD, ENGVPN_PREFIX, ENGVPN_LOCAL_PACKAGE, ENGVPN_FEED, …

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

# Interactive: list JFFS + USB candidates with free space; default JFFS when it fits.
# UI goes to /dev/tty so `prefix=$(prompt_prefix)` only captures the path.
prompt_prefix() {
	jffs_free=$(space_kb /jffs "$JFFS_PREFIX")
	{
		echo "Куда установить EngVPN?"
		echo "[1] Роутер (JFFS) — свободно ~$(mb_of "$jffs_free") МБ — $JFFS_PREFIX"
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
		echo "[$n] Флешка $name — свободно ~$(mb_of "$drive") МБ — $mount/engvpn" >/dev/tty
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
	feed=$(curl -fsS --retry 3 "$FEED") || fail "не удалось скачать $FEED"
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
		fail "в ленте нет пакета для $key"
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
	archive=$WORK/engvpn.tar.gz
	case "$url" in
	file://*)
		src=${url#file://}
		cp -f "$src" "$archive" || fail "не удалось скопировать $src"
		;;
	*)
		curl -fsS --retry 3 -o "$archive" "$url" || fail "не удалось скачать пакет"
		;;
	esac

	stage "Проверка" "Проверка SHA-256 и подписи…"
	if type sha256sum >/dev/null 2>&1; then
		actual=$(sha256sum "$archive" | awk '{ print $1 }')
	else
		actual=$(openssl dgst -sha256 -r "$archive" | awk '{ print $1 }')
	fi
	[ "$actual" = "$sha256" ] || fail "контрольная сумма пакета не совпадает с лентой"
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
		pub_url=${ENGVPN_MINISIGN_PUB:-https://raw.githubusercontent.com/Homavi88/Stealthsurf-Asus/main/engvpn/keys/engvpn.minisign.pub}
		pub=$WORK/engvpn.minisign.pub
		curl -fsS --retry 2 -o "$pub" "$pub_url" 2>/dev/null || true
		if [ -f "$pub" ] && command -v minisign >/dev/null 2>&1; then
			minisign -Vm "$archive" -x "$sig" -p "$pub" || fail "проверка Minisign не прошла"
			echo "  → Minisign OK"
		elif [ -f "$pub" ] && command -v node >/dev/null 2>&1; then
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
echo
echo "EngVPN $version установлен в $prefix."
echo "Панель: http://${lan:-192.168.50.1}:8790 — войдите с выбранным паролем"
echo "Пути: не трогает /jffs/addons/stealthsurf (:8800) и /jffs/addons/ssurf (:1131)"
