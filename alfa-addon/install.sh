#!/bin/sh
# StealthSurf Alfa — установка одной командой на Asuswrt-Merlin.
#
#   /opt/bin/curl -fsSL https://raw.githubusercontent.com/Homavi88/Stealthsurf-Asus/main/alfa-addon/install.sh | sh
#
# Удаление:
#   /opt/bin/curl -fsSL https://raw.githubusercontent.com/Homavi88/Stealthsurf-Asus/main/alfa-addon/install.sh | sh -s -- uninstall
#
# Каталог: /jffs/addons/alfa · служба: /jffs/scripts/alfa · панель: :8788
# Не трогает SurfGate (:1131) и официальный StealthSurf (:8800).
#
# На Merlin opkg часто зовёт BusyBox wget без HTTPS → «not an http or ftp url».
# Этот скрипт подставляет curl-обёртку wget и при необходимости качает .ipk сам.
set -e

export PATH="/opt/bin:/opt/sbin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

ADDON_REPO="${ADDON_REPO:-Homavi88/Stealthsurf-Asus}"
ADDON_REF="${ADDON_REF:-main}"
OUR_DIR="/jffs/addons/alfa"
OUR_SCRIPT="/jffs/scripts/alfa"
OFFICIAL_DIR="/jffs/addons/stealthsurf"
SSURF_DIR="/jffs/addons/ssurf"
TMP_ROOT="/tmp/alfa-install.$$"
PORT=8788
WGET_SHIM_DIR="/tmp/alfa-bin.$$"

C0='\033[0m'
CGREEN='\033[0;32m'
CRED='\033[0;31m'
CYELLOW='\033[0;33m'
CCYAN='\033[0;36m'
CDIM='\033[0;90m'
CBLD='\033[1m'
if [ -t 1 ]; then UI_COLOR=1; else UI_COLOR=0; fi

say() { if [ "$UI_COLOR" -eq 1 ]; then printf '%b›%b %s\n' "$CCYAN" "$C0" "$*"; else echo "==> $*"; fi; }
ok()  { if [ "$UI_COLOR" -eq 1 ]; then printf '  %b✓%b %s\n' "$CGREEN" "$C0" "$*"; else echo "  [ok] $*"; fi; }
fail(){ if [ "$UI_COLOR" -eq 1 ]; then printf '  %b✗%b %s\n' "$CRED" "$C0" "$*" >&2; else echo "  [fail] $*" >&2; fi; }
warn(){ if [ "$UI_COLOR" -eq 1 ]; then printf '  %b!%b %s\n' "$CYELLOW" "$C0" "$*"; else echo "  [warn] $*"; fi; }

cleanup() {
  rm -rf "$TMP_ROOT" "$WGET_SHIM_DIR" 2>/dev/null || true
}
trap cleanup EXIT

banner() {
  if [ "$UI_COLOR" -eq 1 ]; then
    printf '\n%b┌─ %sStealthSurf Alfa%s ──────────────────────────┐%b\n' "$CCYAN" "$CBLD" "$CCYAN" "$C0"
    printf '%b│%b 0.1.0-alpha · panel :%s · /jffs/addons/alfa%b│%b\n' "$CCYAN" "$CDIM" "$PORT" "$CCYAN" "$C0"
    printf '%b└─────────────────────────────────────────────────┘%b\n\n' "$CCYAN" "$C0"
  else
    echo "==> StealthSurf Alfa installer (panel :$PORT, path $OUR_DIR)"
  fi
}

need_https() {
  if [ -x /opt/bin/curl ]; then
    CURL=/opt/bin/curl
  elif command -v curl >/dev/null 2>&1; then
    CURL="$(command -v curl)"
  else
    fail "нужен curl с HTTPS (есть у вас для этой команды — проверьте PATH)"
    exit 1
  fi
  ok "HTTPS: $CURL"
}

# BusyBox wget не умеет https. opkg всё равно зовёт «wget» — подсовываем curl.
install_wget_shim() {
  mkdir -p "$WGET_SHIM_DIR"
  cat >"$WGET_SHIM_DIR/wget" << EOF
#!/bin/sh
OUT=""
URL=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -O|--output-document)
      OUT="\$2"; shift 2 ;;
    -O*)
      OUT="\${1#-O}"; shift ;;
    --output-document=*)
      OUT="\${1#*=}"; shift ;;
    -q|--quiet|-nv|--no-verbose)
      shift ;;
    -T|--timeout|--connect-timeout|--tries|--dns-timeout|--read-timeout)
      shift 2 ;;
    --timeout=*|--connect-timeout=*|--tries=*|--no-check-certificate|--no-cache|--no-cookies)
      shift ;;
    --header|--user-agent|-U|--referer|-e|--execute)
      shift 2 ;;
    -*)
      shift ;;
    *)
      URL="\$1"; shift ;;
  esac
done
[ -n "\$URL" ] || exit 1
if [ -n "\$OUT" ]; then
  exec "$CURL" -fsSL --connect-timeout 30 --retry 2 -o "\$OUT" "\$URL"
fi
exec "$CURL" -fsSL --connect-timeout 30 --retry 2 "\$URL"
EOF
  chmod +x "$WGET_SHIM_DIR/wget"
  export PATH="$WGET_SHIM_DIR:/opt/bin:/opt/sbin:/usr/sbin:/usr/bin:/sbin:/bin"
  ok "wget→curl для opkg"
}

entware_feed() {
  # https://bin.entware.net/aarch64-k3.10
  awk '/^src\/gz/{print $3; exit}' /opt/etc/opkg.conf 2>/dev/null
}

http_feed() {
  feed="$(entware_feed)"
  echo "$feed" | sed 's|^https://|http://|'
}

# Entware отдаёт те же пакеты по HTTP. HTTPS на части роутеров/сетей рвётся
# (BusyBox wget и иногда даже curl: SSL_ERROR_SYSCALL) — для .ipk берём HTTP первым.
preferred_feed() {
  http="$(http_feed)"
  [ -n "$http" ] && echo "$http" && return 0
  entware_feed
}

fetch() {
  # $1 url $2 outfile
  "$CURL" -fsSL --connect-timeout 30 --retry 2 -o "$2" "$1"
}

fetch_entware() {
  # $1 relative path or absolute url under feed, $2 outfile
  rel="$1"
  out="$2"
  base="$(preferred_feed)"
  if fetch "$base/$rel" "$out"; then
    return 0
  fi
  https="$(entware_feed)"
  [ -n "$https" ] && [ "$https" != "$base" ] && fetch "$https/$rel" "$out"
}

preflight() {
  if [ ! -d /jffs ]; then
    fail "/jffs не найден. Включите JFFS custom scripts: Administration → System"
    exit 1
  fi
  if [ ! -x /opt/bin/opkg ]; then
    fail "нужен Entware (/opt/bin/opkg)"
    echo "    https://github.com/Entware/Entware/wiki/Install-on-ASUSWRT" >&2
    exit 1
  fi
  ok "JFFS + Entware"
  if [ -d "$SSURF_DIR" ]; then ok "SurfGate рядом ($SSURF_DIR) — не трогаем"; fi
  if [ -d "$OFFICIAL_DIR" ]; then ok "официальный StealthSurf рядом ($OFFICIAL_DIR) — не трогаем"; fi
  feed="$(entware_feed)"
  if [ -n "$feed" ]; then ok "фид Entware: $feed"; else warn "не прочитал /opt/etc/opkg.conf"; fi
}

opkg_update_safe() {
  install_wget_shim
  if /opt/bin/opkg update; then
    ok "opkg update"
    return 0
  fi
  warn "opkg update по HTTPS не прошёл — пробую HTTP-фид"
  feed_http="$(http_feed)"
  [ -n "$feed_http" ] || return 1
  conf_bak="$TMP_ROOT/opkg.conf.bak"
  mkdir -p "$TMP_ROOT"
  cp /opt/etc/opkg.conf "$conf_bak"
  # временно http:// — BusyBox wget такое умеет; shim тоже
  sed 's|https://bin.entware.net/|http://bin.entware.net/|g' "$conf_bak" >/opt/etc/opkg.conf
  if /opt/bin/opkg update; then
    ok "opkg update по HTTP"
    # вернём https в conf — дальше shim закроет HTTPS
    cp "$conf_bak" /opt/etc/opkg.conf
    return 0
  fi
  cp "$conf_bak" /opt/etc/opkg.conf
  return 1
}

# Скачать Packages и поставить пакет .ipk (+ прямые Depends) через curl, минуя wget.
opkg_install_via_curl() {
  pkg="$1"
  feed="$(preferred_feed)"
  [ -n "$feed" ] || return 1
  mkdir -p "$TMP_ROOT/ipk"
  idx="$TMP_ROOT/Packages"
  say "качаю индекс пакетов ($pkg) с $feed"
  fetch_entware "Packages.gz" "$TMP_ROOT/Packages.gz" || return 1
  gzip -dc "$TMP_ROOT/Packages.gz" >"$idx" 2>/dev/null || gunzip -c "$TMP_ROOT/Packages.gz" >"$idx"

  lookup_field() {
    # $1 package $2 field name → value
    awk -v want="$1" -v field="$2" '
      BEGIN { FS=": " }
      /^Package: / { p=$2; next }
      $1 == field && p == want { print $2; exit }
    ' "$idx"
  }

  file="$(lookup_field "$pkg" Filename)"
  [ -n "$file" ] || {
    fail "в индексе нет пакета $pkg"
    return 1
  }

  # зависимости первого уровня (без версий)
  deps="$(lookup_field "$pkg" Depends | tr ',' '\n' | sed 's/^ *//;s/ .*//;/^$/d' | grep -vE '^(libc|libssp|librt|libpthread)$' || true)"
  for dep in $deps; do
    if /opt/bin/opkg list-installed "$dep" 2>/dev/null | grep -q .; then
      continue
    fi
    dfile="$(lookup_field "$dep" Filename)"
    [ -n "$dfile" ] || continue
    say "зависимость $dep"
    fetch_entware "$dfile" "$TMP_ROOT/ipk/$dfile" || continue
    /opt/bin/opkg install --force-overwrite "$TMP_ROOT/ipk/$dfile" || true
  done

  say "ставлю $pkg ($file)"
  fetch_entware "$file" "$TMP_ROOT/ipk/$file" || return 1
  /opt/bin/opkg install --force-overwrite "$TMP_ROOT/ipk/$file"
}

ensure_node() {
  if command -v node >/dev/null 2>&1; then
    ok "node $(node -v 2>/dev/null || echo ok)"
    return 0
  fi
  say "ставлю Node.js из Entware"
  mkdir -p "$TMP_ROOT"

  if opkg_update_safe; then
    # на aarch64-k3.10 пакет называется node, не nodejs
    if /opt/bin/opkg install node || /opt/bin/opkg install nodejs; then
      :
    else
      warn "opkg install node не вышел — качаю .ipk через curl"
      opkg_install_via_curl node || opkg_install_via_curl nodejs || {
        fail "не удалось поставить node"
        exit 1
      }
    fi
  else
    warn "opkg update недоступен — качаю node.ipk через curl"
    opkg_install_via_curl node || opkg_install_via_curl nodejs || {
      fail "не удалось поставить node (ни opkg, ни прямая загрузка)"
      echo "    Проверьте: $CURL -fsSIL \$(awk '/^src\\/gz/{print \$3;exit}' /opt/etc/opkg.conf)/Packages.gz" >&2
      exit 1
    }
  fi

  # обновить PATH на случай свежего /opt/bin/node
  export PATH="/opt/bin:/opt/sbin:$PATH"
  hash -r 2>/dev/null || true
  if ! command -v node >/dev/null 2>&1; then
    fail "после установки нет команды node"
    exit 1
  fi
  ok "node $(node -v 2>/dev/null || echo installed)"
}

download_addon() {
  say "скачиваю alfa-addon ($ADDON_REPO@$ADDON_REF)"
  mkdir -p "$TMP_ROOT"
  ARCHIVE="$TMP_ROOT/repo.tgz"
  URL="https://github.com/${ADDON_REPO}/archive/refs/heads/${ADDON_REF}.tar.gz"
  if ! fetch "$URL" "$ARCHIVE"; then
    URL="https://github.com/${ADDON_REPO}/archive/refs/heads/master.tar.gz"
    fetch "$URL" "$ARCHIVE"
  fi
  tar -tzf "$ARCHIVE" >/dev/null 2>&1 || {
    fail "архив битый"
    exit 1
  }
  mkdir -p "$TMP_ROOT/extract"
  tar -xzf "$ARCHIVE" -C "$TMP_ROOT/extract"
  SRC="$(find "$TMP_ROOT/extract" -type d -name alfa-addon 2>/dev/null | head -n 1)"
  [ -n "$SRC" ] && [ -f "$SRC/server.mjs" ] || {
    fail "в архиве нет alfa-addon/server.mjs"
    exit 1
  }
  ok "пакет найден"
  echo "$SRC" >"$TMP_ROOT/src.path"
}

install_files() {
  SRC="$(cat "$TMP_ROOT/src.path")"
  say "кладём файлы в $OUR_DIR"
  mkdir -p /jffs/addons /jffs/scripts
  mkdir -p "$OUR_DIR"
  if [ -d "$OUR_DIR/data" ]; then
    cp -a "$OUR_DIR/data" "$TMP_ROOT/data.bak"
    ok "сохранил data/"
  fi
  rm -rf "$OUR_DIR"
  mkdir -p "$OUR_DIR"
  cp -a "$SRC"/. "$OUR_DIR"/
  rm -rf "$OUR_DIR/data"
  if [ -d "$TMP_ROOT/data.bak" ]; then
    mv "$TMP_ROOT/data.bak" "$OUR_DIR/data"
    ok "вернул data/"
  else
    mkdir -p "$OUR_DIR/data"
  fi
  chmod +x "$OUR_DIR/scripts/alfa" 2>/dev/null || true
  chmod +x "$OUR_DIR/install.sh" 2>/dev/null || true
  ok "файлы на месте"
}

install_service() {
  say "служба $OUR_SCRIPT"
  if [ -f "$OUR_DIR/scripts/alfa" ]; then
    cp -f "$OUR_DIR/scripts/alfa" "$OUR_SCRIPT"
  else
    fail "нет scripts/alfa в пакете"
    exit 1
  fi
  chmod +x "$OUR_SCRIPT"
  touch /jffs/scripts/post-mount
  chmod +x /jffs/scripts/post-mount
  if ! grep -q 'scripts/alfa start' /jffs/scripts/post-mount 2>/dev/null; then
    echo '/jffs/scripts/alfa start #alfa' >>/jffs/scripts/post-mount
  fi
  ok "автозапуск в post-mount"
}

start_panel() {
  say "запускаю панель"
  "$OUR_SCRIPT" restart
  i=0
  while [ "$i" -lt 20 ]; do
    if command -v curl >/dev/null 2>&1 || [ -x /opt/bin/curl ]; then
      code="$("$CURL" -fsS -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/" 2>/dev/null || echo 000)"
      if [ "$code" = "200" ]; then
        ok "панель отвечает http://127.0.0.1:${PORT}/ → $code"
        return 0
      fi
    elif "$OUR_SCRIPT" status >/dev/null 2>&1; then
      ok "процесс панели запущен"
      return 0
    fi
    i=$((i + 1))
    sleep 1
  done
  warn "панель ещё не ответила — смотрите /tmp/alfa-panel.log"
  tail -n 30 /tmp/alfa-panel.log 2>/dev/null || true
}

lan_hint() {
  ip="$(nvram get lan_ipaddr 2>/dev/null || true)"
  [ -n "$ip" ] || ip="192.168.50.1"
  echo
  ok "готово"
  echo "  панель:  http://${ip}:${PORT}/"
  echo "  пароль:  alfa"
  echo "  статус:  $OUR_SCRIPT status"
  echo "  стоп:    $OUR_SCRIPT stop"
  echo "  удалить: $OUR_SCRIPT uninstall"
  echo "  ядра:    в панели → Движок → скачать Xray / sing-box / mihomo"
  echo
}

do_uninstall() {
  banner
  say "удаляю StealthSurf Alfa"
  if [ -x "$OUR_SCRIPT" ]; then
    "$OUR_SCRIPT" uninstall
  else
    if [ -f /var/run/alfa.pid ]; then
      kill "$(cat /var/run/alfa.pid)" 2>/dev/null || true
      rm -f /var/run/alfa.pid
    fi
    if [ -f /jffs/scripts/post-mount ]; then
      sed -i '/#alfa$/d' /jffs/scripts/post-mount 2>/dev/null || true
      sed -i '/\/jffs\/scripts\/alfa /d' /jffs/scripts/post-mount 2>/dev/null || true
    fi
    rm -f "$OUR_SCRIPT" /tmp/alfa-panel.log
    rm -rf "$OUR_DIR"
    ok "каталог и служба удалены"
  fi
  [ -d "$SSURF_DIR" ] && ok "SurfGate на месте"
  [ -d "$OFFICIAL_DIR" ] && ok "официальный StealthSurf на месте"
  echo
}

do_install() {
  banner
  need_https
  preflight
  ensure_node
  download_addon
  install_files
  install_service
  start_panel
  lan_hint
}

case "${1:-install}" in
  uninstall|remove|un)
    do_uninstall
    ;;
  install|*)
    do_install
    ;;
esac
