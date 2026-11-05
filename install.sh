#!/bin/sh
# StealthSurf Asuswrt-Merlin — one-command installer
# Usage on router (Entware must already be installed via amtm):
#   curl -fsSL https://raw.githubusercontent.com/Homavi88/Stealthsurf-Asus/main/install.sh | sh
#   wget -qO- https://raw.githubusercontent.com/Homavi88/Stealthsurf-Asus/main/install.sh | sh
# Disable colors: NO_COLOR=1 curl … | sh

set -e

REPO_RAW="https://raw.githubusercontent.com/Homavi88/Stealthsurf-Asus/main"
REPO_TARBALL_RAW="${REPO_RAW}/packaged/asuswrt-merlin-stealthsurf.tar.gz"
REPO_TARBALL_RELEASE="https://github.com/Homavi88/Stealthsurf-Asus/releases/latest/download/asuswrt-merlin-stealthsurf.tar.gz"

ADDON_TAG="stealthsurf"
TMP_TGZ="/tmp/asuswrt-merlin-stealthsurf.tar.gz"
ADDON_DIR="/jffs/addons/${ADDON_TAG}"
SCRIPT_DST="/jffs/scripts/${ADDON_TAG}"

SS_STEP=0
SS_STEPS=6
OPKG=""

# Absolute PATH for Merlin SSH / curl|sh (login profile may not be sourced)
ss_export_path() {
  export PATH="/opt/bin:/opt/sbin:/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin${PATH:+:$PATH}"
}

ss_find_opkg() {
  OPKG=""
  if [ -x /opt/bin/opkg ]; then
    OPKG="/opt/bin/opkg"
  elif [ -x /opt/sbin/opkg ]; then
    OPKG="/opt/sbin/opkg"
  elif [ -x /opt/usr/bin/opkg ]; then
    OPKG="/opt/usr/bin/opkg"
  fi
  [ -n "$OPKG" ]
}

# ── colors (TTY only; respect NO_COLOR) ───────────────────────────────
ss_color_init() {
  C_RESET="" C_BOLD="" C_DIM=""
  C_RED="" C_GRN="" C_YEL="" C_CYN="" C_BLU="" C_WHT=""
  if [ -n "${NO_COLOR:-}" ]; then
    return 0
  fi
  # curl|sh: stdout may be pipe; UI goes to stderr which is often a TTY
  if [ -t 2 ] || [ -t 1 ]; then
    C_RESET="$(printf '\033[0m')"
    C_BOLD="$(printf '\033[1m')"
    C_DIM="$(printf '\033[2m')"
    C_RED="$(printf '\033[31m')"
    C_GRN="$(printf '\033[32m')"
    C_YEL="$(printf '\033[33m')"
    C_BLU="$(printf '\033[34m')"
    C_CYN="$(printf '\033[36m')"
    C_WHT="$(printf '\033[37m')"
  fi
}

ss_out() { printf '%s\n' "$*" >&2; }
ss_blank() { printf '\n' >&2; }

banner() {
  ss_out "${C_CYN}${C_BOLD}"
  ss_out "  +====================================================+"
  ss_out "  |                                                    |"
  ss_out "  |   ${C_WHT}##### ##### ######   #   #     #####             ${C_CYN}${C_BOLD}|"
  ss_out "  |   ${C_WHT}#       #   #       # #  #     #                 ${C_CYN}${C_BOLD}|"
  ss_out "  |   ${C_WHT}#####   #   #####  ##### #     #####             ${C_CYN}${C_BOLD}|"
  ss_out "  |   ${C_WHT}    #   #   #      #   # #         #             ${C_CYN}${C_BOLD}|"
  ss_out "  |   ${C_WHT}#####   #   ###### #   # ##### #####             ${C_CYN}${C_BOLD}|"
  ss_out "  |                                                    |"
  ss_out "  |   ${C_GRN}StealthSurf${C_CYN}${C_BOLD}  ·  Asuswrt-Merlin addon               |"
  ss_out "  |   ${C_DIM}VPN control plane on your router${C_RESET}${C_CYN}${C_BOLD}                  |"
  ss_out "  |                                                    |"
  ss_out "  +====================================================+"
  ss_out "${C_RESET}"
}

hr() {
  ss_out "${C_DIM}  ----------------------------------------------------${C_RESET}"
}

step_begin() {
  SS_STEP=$((SS_STEP + 1))
  ss_blank
  ss_out "${C_BLU}${C_BOLD}  >> [${SS_STEP}/${SS_STEPS}]${C_RESET} ${C_BOLD}$*${C_RESET}"
}

ok() {
  ss_out "  ${C_GRN}[OK]${C_RESET} $*"
}

info() {
  ss_out "  ${C_CYN} * ${C_RESET}$*"
}

warn() {
  ss_out "  ${C_YEL}[!]${C_RESET} ${C_YEL}$*${C_RESET}"
}

die() {
  ss_blank
  ss_out "  ${C_RED}${C_BOLD}[FAIL]${C_RESET} ${C_RED}$*${C_RESET}"
  ss_blank
  exit 1
}

require_rootish() {
  step_begin "Проверка доступа к JFFS"
  touch /jffs/.stealthsurf_write_test 2>/dev/null || die "Нет записи в /jffs (включите JFFS custom scripts)"
  rm -f /jffs/.stealthsurf_write_test
  ok "Запись в /jffs разрешена"
}

check_merlin_jffs() {
  step_begin "Asuswrt-Merlin / JFFS"
  ss_export_path
  if [ ! -d /jffs ]; then
    die "/jffs не найден — нужен Asuswrt-Merlin с JFFS"
  fi
  ok "Каталог /jffs найден"
  NVRAM=""
  if [ -x /bin/nvram ]; then
    NVRAM=/bin/nvram
  elif [ -x /sbin/nvram ]; then
    NVRAM=/sbin/nvram
  elif [ -x /usr/sbin/nvram ]; then
    NVRAM=/usr/sbin/nvram
  fi
  if [ -n "$NVRAM" ]; then
    jffs_enable=$("$NVRAM" get jffs2_scripts 2>/dev/null || true)
    if [ "$jffs_enable" = "0" ]; then
      die "JFFS custom scripts выключены. Administration -> System -> Enable JFFS custom scripts = Yes, затем reboot"
    fi
    ok "JFFS custom scripts включены (jffs2_scripts=$jffs_enable)"
  else
    warn "nvram недоступен — проверьте вручную: Enable JFFS custom scripts = Yes"
  fi
}

check_entware() {
  step_begin "Entware"
  ss_export_path

  # Entware на Merlin живёт на USB и монтируется в /opt (часто через post-mount)
  if [ ! -d /opt ]; then
    die "Нет /opt. Сначала в amtm установите Entware, подождите mount USB, повторите install"
  fi

  # Подтянуть PATH Entware, если profile есть (USB уже смонтирован)
  if [ -f /opt/etc/profile ]; then
    # shellcheck disable=SC1091
    . /opt/etc/profile 2>/dev/null || true
    ss_export_path
  fi

  if ! ss_find_opkg; then
    ss_blank
    ss_out "  ${C_YEL}Диагностика /opt:${C_RESET}"
    info "ls /opt → $(ls /opt 2>/dev/null | tr '\n' ' ' | cut -c1-80)"
    info "USB/Entware часто ещё не смонтирован после reboot"
    ss_blank
    die "Entware/opkg не найден. Откройте amtm → установите Entware → убедитесь: ls -l /opt/bin/opkg"
  fi

  # Проверяем, что бинарь реально запускается (не битый mount)
  if ! "$OPKG" --version >/dev/null 2>&1 && ! "$OPKG" version >/dev/null 2>&1 && ! "$OPKG" 2>/dev/null | head -1 >/dev/null; then
    # некоторые сборки opkg печатают usage и exit 1 без аргументов — это OK, файл живой
    if [ ! -s "$OPKG" ]; then
      die "Файл $OPKG пустой/битый. Переустановите Entware через amtm"
    fi
  fi

  ok "Entware OK → ${C_GRN}$OPKG${C_RESET}"
  info "PATH: ${C_DIM}$(printf '%s' "$PATH" | cut -c1-72)…${C_RESET}"
}

install_entware_deps() {
  step_begin "Зависимости Entware"
  ss_export_path
  ss_find_opkg || die "opkg пропал перед установкой зависимостей"
  info "opkg update ($OPKG)..."
  "$OPKG" update >/dev/null 2>&1 || warn "opkg update не удался — продолжаю с локальным индексом"

  for spec in \
    "curl:curl" \
    "jq:jq" \
    "ca-certificates:ca-certificates" \
    "libopenssl:libopenssl openssl-util" \
    "coreutils-base64:coreutils-base64" \
    "flock:flock" \
    "iptables:iptables" \
    "ipset:ipset" \
    "unzip:unzip"
  do
    pkg=${spec%%:*}
    alts=${spec#*:}
    if "$OPKG" list-installed 2>/dev/null | grep -q "^${pkg} "; then
      ok "уже есть: ${C_DIM}$pkg${C_RESET}"
      continue
    fi
    installed=0
    for cand in $alts; do
      if "$OPKG" install "$cand" >/dev/null 2>&1; then
        ok "установлен: ${C_GRN}$cand${C_RESET}"
        installed=1
        break
      fi
    done
    if [ "$installed" -ne 1 ]; then
      warn "не удалось поставить '$pkg' (пробовал: $alts)"
    fi
  done

  if [ ! -x /opt/sbin/xray ] && [ ! -x /opt/bin/xray ]; then
    for cand in xray xray-core; do
      if "$OPKG" install "$cand" >/dev/null 2>&1; then
        ok "dataplane: ${C_GRN}$cand${C_RESET}"
        break
      fi
    done
  else
    ok "xray уже на роутере"
  fi

  if [ ! -x /opt/sbin/xray ] && [ ! -x /opt/bin/xray ]; then
    info "Xray не в opkg — скачается на шаге install аддона (ssurf xray)"
  fi

  if [ ! -x /opt/bin/unzip ] && [ ! -x /usr/bin/unzip ] && ! type unzip >/dev/null 2>&1; then
    "$OPKG" install unzip >/dev/null 2>&1 || warn "unzip отсутствует — скачивание Xray с GitHub может не сработать"
  fi

  CURL_BIN=""
  if [ -x /opt/bin/curl ]; then
    CURL_BIN=/opt/bin/curl
  elif [ -x /usr/bin/curl ]; then
    CURL_BIN=/usr/bin/curl
  elif type curl >/dev/null 2>&1; then
    CURL_BIN=$(type curl 2>/dev/null | awk '{print $NF}')
  fi
  JQ_BIN=""
  if [ -x /opt/bin/jq ]; then
    JQ_BIN=/opt/bin/jq
  elif type jq >/dev/null 2>&1; then
    JQ_BIN=$(type jq 2>/dev/null | awk '{print $NF}')
  fi
  [ -n "$CURL_BIN" ] || die "curl обязателен — поставьте через amtm/opkg: opkg install curl"
  [ -n "$JQ_BIN" ] || die "jq обязателен — поставьте: /opt/bin/opkg install jq"
  ok "curl + jq готовы ($CURL_BIN, $JQ_BIN)"
}

download_package() {
  step_begin "Скачивание пакета"
  rm -f "$TMP_TGZ"
  info "GitHub Releases (latest)..."
  ss_export_path

  _curl=""
  if [ -x /opt/bin/curl ]; then
    _curl=/opt/bin/curl
  elif [ -x /usr/bin/curl ]; then
    _curl=/usr/bin/curl
  elif [ -n "${CURL_BIN:-}" ]; then
    _curl=$CURL_BIN
  fi

  if [ -n "$_curl" ]; then
    if "$_curl" -fsSL -o "$TMP_TGZ" "$REPO_TARBALL_RELEASE" 2>/dev/null; then
      ok "Скачано из ${C_GRN}GitHub Releases${C_RESET}"
      sz=$(wc -c <"$TMP_TGZ" 2>/dev/null | tr -d ' ')
      info "размер: ${C_DIM}${sz} bytes${C_RESET}"
      return 0
    fi
    warn "Releases недоступны — пробую packaged/ на main"
    if "$_curl" -fsSL -o "$TMP_TGZ" "$REPO_TARBALL_RAW" 2>/dev/null; then
      ok "Скачано из репозитория ${C_DIM}packaged/${C_RESET}"
      return 0
    fi
  fi

  _wget=""
  if [ -x /opt/bin/wget ]; then
    _wget=/opt/bin/wget
  elif [ -x /usr/bin/wget ]; then
    _wget=/usr/bin/wget
  fi
  if [ -n "$_wget" ]; then
    if "$_wget" -q -O "$TMP_TGZ" "$REPO_TARBALL_RELEASE" 2>/dev/null; then
      ok "Скачано из GitHub Releases (wget)"
      return 0
    fi
    if "$_wget" -q -O "$TMP_TGZ" "$REPO_TARBALL_RAW" 2>/dev/null; then
      ok "Скачано из packaged/ (wget)"
      return 0
    fi
  fi

  die "Не удалось скачать пакет. Проверьте сеть / доступ к GitHub с роутера"
}

extract_and_place() {
  step_begin "Распаковка и установка файлов"
  [ -s "$TMP_TGZ" ] || die "Пустой архив пакета"
  info "цель: ${C_DIM}$ADDON_DIR${C_RESET}"
  rm -rf "$ADDON_DIR"
  mkdir -p /jffs/addons /jffs/scripts
  tar -xzf "$TMP_TGZ" -C /jffs/addons
  [ -f "$ADDON_DIR/stealthsurf" ] || die "В архиве нет $ADDON_DIR/stealthsurf"
  [ -f "$ADDON_DIR/index.asp" ] || die "В архиве нет index.asp"
  [ -f "$ADDON_DIR/app.js" ] || die "В архиве нет app.js"

  mv -f "$ADDON_DIR/stealthsurf" "$SCRIPT_DST"
  chmod 0755 "$SCRIPT_DST"
  ln -sf "$SCRIPT_DST" "/opt/bin/${ADDON_TAG}" 2>/dev/null || true
  ln -sf "$SCRIPT_DST" "/opt/bin/ssurf" 2>/dev/null || true
  ok "скрипт: ${C_DIM}$SCRIPT_DST${C_RESET}"
  ok "CLI: ${C_GRN}ssurf${C_RESET} / stealthsurf"
}

run_addon_install() {
  step_begin "Настройка аддона (хуки, UI, Xray)"
  info "запуск: ${C_DIM}$SCRIPT_DST install${C_RESET}"
  sh "$SCRIPT_DST" install || die "Шаг install аддона завершился с ошибкой"
  ok "хуки Merlin, UI и cron установлены"
}

finale() {
  ver="?"
  if [ -x "$SCRIPT_DST" ]; then
    ver=$("$SCRIPT_DST" version 2>/dev/null | head -1 | awk '{print $NF}')
  fi
  lan="$(nvram get lan_ipaddr 2>/dev/null || echo 192.168.1.1)"
  ss_blank
  hr
  ss_out "${C_GRN}${C_BOLD}"
  ss_out "  +====================================================+"
  ss_out "  |   [OK]  StealthSurf установлен!   v${ver}              |"
  ss_out "  +====================================================+"
  ss_out "${C_RESET}"
  ss_out "  ${C_BOLD}Дальше:${C_RESET}"
  ss_out "  ${C_CYN}1.${C_RESET} Выйдите из WebUI и зайдите снова"
  ss_out "  ${C_CYN}2.${C_RESET} Откройте ${C_BOLD}VPN -> StealthSurf${C_RESET}"
  ss_out "     ${C_DIM}http://${lan}/user1.asp${C_RESET}"
  ss_blank
  ss_out "  ${C_BOLD}CLI:${C_RESET}"
  ss_out "     ${C_GRN}ssurf key${C_RESET} 'stlth_...'"
  ss_out "     ${C_GRN}ssurf sy${C_RESET} && ${C_GRN}ssurf ls${C_RESET}"
  ss_out "     ${C_GRN}ssurf ap${C_RESET} <id> && ${C_GRN}ssurf mode${C_RESET} redirect && ${C_GRN}ssurf up${C_RESET}"
  ss_out "     ${C_GRN}ssurf m${C_RESET}     ${C_DIM}# меню${C_RESET}"
  ss_out "     ${C_GRN}ssurf h${C_RESET}     ${C_DIM}# справка${C_RESET}"
  ss_blank
  hr
  ss_blank
}

main() {
  ss_color_init
  ss_export_path
  banner
  hr
  info "Установщик one-liner · Entware обязателен (amtm)"
  info "Цвета: ${C_GRN}вкл${C_RESET}${C_DIM} (NO_COLOR=1 чтобы выключить)${C_RESET}"
  require_rootish
  check_merlin_jffs
  check_entware
  install_entware_deps
  download_package
  extract_and_place
  run_addon_install
  rm -f "$TMP_TGZ"
  finale
}

main "$@"
