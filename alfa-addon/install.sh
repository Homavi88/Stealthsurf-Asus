#!/bin/sh
# StealthSurf Alfa — установка одной командой на Asuswrt-Merlin.
#
#   /opt/bin/curl -fsSL https://raw.githubusercontent.com/Homavi88/Stealthsurf-Asus/main/alfa-addon/install.sh | sh
#
# Удаление:
#   /opt/bin/curl -fsSL https://raw.githubusercontent.com/Homavi88/Stealthsurf-Asus/main/alfa-addon/install.sh | sh -s -- uninstall
#   или: /jffs/scripts/alfa uninstall
#
# Каталог: /jffs/addons/alfa · служба: /jffs/scripts/alfa · панель: :8788
# Не трогает SurfGate (:1131) и официальный StealthSurf (:8800).
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
  rm -rf "$TMP_ROOT" 2>/dev/null || true
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
    DL="/opt/bin/curl -fsSL"
  elif command -v curl >/dev/null 2>&1; then
    DL="curl -fsSL"
  else
    fail "нужен curl с HTTPS (Entware: opkg install curl)"
    exit 1
  fi
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
}

ensure_node() {
  if command -v node >/dev/null 2>&1; then
    ok "node $(node -v 2>/dev/null || echo ok)"
    return 0
  fi
  say "ставлю Node.js из Entware"
  /opt/bin/opkg update || warn "opkg update не удался — пробую кэш"
  if /opt/bin/opkg install nodejs; then
    :
  elif /opt/bin/opkg install node; then
    :
  else
    fail "не удалось поставить node/nodejs через opkg"
    exit 1
  fi
  command -v node >/dev/null 2>&1 || {
    fail "после opkg нет команды node"
    exit 1
  }
  ok "node $(node -v 2>/dev/null || echo installed)"
}

download_addon() {
  say "скачиваю alfa-addon ($ADDON_REPO@$ADDON_REF)"
  mkdir -p "$TMP_ROOT"
  ARCHIVE="$TMP_ROOT/repo.tgz"
  URL="https://github.com/${ADDON_REPO}/archive/refs/heads/${ADDON_REF}.tar.gz"
  # shellcheck disable=SC2086
  $DL "$URL" -o "$ARCHIVE" || {
    # fallback: tags as refs/tags/ — try heads only; if fail, try master
    URL="https://github.com/${ADDON_REPO}/archive/refs/heads/master.tar.gz"
    $DL "$URL" -o "$ARCHIVE"
  }
  tar -tzf "$ARCHIVE" >/dev/null 2>&1 || {
    fail "архив битый"
    exit 1
  }
  # вытащить только alfa-addon, без скриншотов alfa/
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
  # сохранить data/ при обновлении
  if [ -d "$OUR_DIR/data" ]; then
    cp -a "$OUR_DIR/data" "$TMP_ROOT/data.bak"
    ok "сохранил data/"
  fi
  # не копировать локальные data/cores из архива (их там нет) и не затирать backup
  rm -rf "$OUR_DIR"
  mkdir -p "$OUR_DIR"
  # копируем содержимое, кроме data если был бэкап — восстановим
  cp -a "$SRC"/. "$OUR_DIR"/
  rm -rf "$OUR_DIR/data"
  if [ -d "$TMP_ROOT/data.bak" ]; then
    mv "$TMP_ROOT/data.bak" "$OUR_DIR/data"
    ok "вернул data/"
  else
    mkdir -p "$OUR_DIR/data"
  fi
  chmod +x "$OUR_DIR/scripts/alfa" 2>/dev/null || true
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
  # короткая проверка
  i=0
  while [ "$i" -lt 15 ]; do
    if command -v curl >/dev/null 2>&1; then
      code="$(curl -fsS -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/" 2>/dev/null || echo 000)"
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
  tail -n 20 /tmp/alfa-panel.log 2>/dev/null || true
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
  echo
}

do_uninstall() {
  banner
  say "удаляю StealthSurf Alfa"
  if [ -x "$OUR_SCRIPT" ]; then
    "$OUR_SCRIPT" uninstall
  else
    # fallback без службы
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
