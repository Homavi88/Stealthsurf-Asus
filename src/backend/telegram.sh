#!/bin/sh
# Telegram Bot control for StealthSurf (long-poll getUpdates via curl)

SS_TG_PIDFILE="${SS_TG_PIDFILE:-/var/run/stealthsurf-telegram.pid}"
SS_TG_OFFSET_FILE="${SS_TG_OFFSET_FILE:-$ADDON_SHARE_DIR/telegram.offset}"
SS_TG_LOG="${SS_TG_LOG:-$ADDON_LOGS_DIR/telegram.log}"
SS_TG_API_BASE="${SS_TG_API_BASE:-https://api.telegram.org}"

ss_telegram_defaults() {
  SS_TG_ENABLED="${SS_TG_ENABLED:-0}"
  SS_TG_BOT_TOKEN="${SS_TG_BOT_TOKEN:-}"
  SS_TG_CHAT_IDS="${SS_TG_CHAT_IDS:-}"
}

ss_telegram_token_hint() {
  local t="$1"
  [ -n "$t" ] || {
    echo ""
    return 0
  }
  local n=${#t}
  if [ "$n" -le 8 ]; then
    echo "****"
    return 0
  fi
  printf '%s\n' "...${t#"${t%????}"}"
}

ss_telegram_mask_token() {
  # Keep previous token when UI sends empty / placeholder
  local incoming="$1"
  case "$incoming" in
  "" | "********" | "***" | "__keep__" | "••••••••")
    printf '%s' "${SS_TG_BOT_TOKEN:-}"
    ;;
  *)
    printf '%s' "$incoming"
    ;;
  esac
}

ss_telegram_normalize_chat_ids() {
  # Accept commas/spaces/semicolons → space-separated digits
  printf '%s' "$1" | tr ',;' '  ' | tr -s ' \t' ' ' | sed 's/^ *//;s/ *$//'
}

ss_telegram_chat_allowed() {
  local chat_id="$1"
  local allowed id
  ss_telegram_defaults
  allowed=$(ss_telegram_normalize_chat_ids "$SS_TG_CHAT_IDS")
  [ -n "$allowed" ] || return 1
  for id in $allowed; do
    [ "$id" = "$chat_id" ] && return 0
  done
  return 1
}

ss_telegram_api() {
  # ss_telegram_api <method> [curl form args...]
  local method="$1"
  shift
  ss_telegram_defaults
  [ -n "$SS_TG_BOT_TOKEN" ] || return 1
  curl -sS --connect-timeout 8 --max-time 40 \
    "$@" \
    "${SS_TG_API_BASE}/bot${SS_TG_BOT_TOKEN}/${method}" 2>/dev/null
}

ss_telegram_send() {
  local chat_id="$1"
  local text="$2"
  [ -n "$chat_id" ] && [ -n "$text" ] || return 1
  # Telegram limit ~4096; keep replies short for routers
  text=$(printf '%s' "$text" | head -c 3500)
  ss_telegram_api sendMessage \
    --data-urlencode "chat_id=${chat_id}" \
    --data-urlencode "text=${text}" \
    --data-urlencode "disable_web_page_preview=true" >/dev/null
}

ss_telegram_log() {
  ss_ensure_dirs 2>/dev/null || true
  mkdir -p "$(dirname "$SS_TG_LOG")" 2>/dev/null || true
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo '?')" "$*" >>"$SS_TG_LOG" 2>/dev/null || true
}

ss_telegram_help_text() {
  cat <<EOF
StealthSurf Telegram-бот

Управление:
  /status — статус VPN
  /on — включить
  /off — выключить
  /restart — перезапустить
  /update — обновить аддон

Каталог и правила:
  /list — VPN-соединения
  /rules — список правил
  /ruleadd <type> <matcher> <outbound> [name]
  /ruleappend … — то же (добавить к существующим)

type: domain|full|keyword|regexp|geosite|geoip|ip|cidr
outbound: ss-<id> | <id> | direct | block

Пример:
  /ruleadd domain youtube.com ss-101
  /ruleappend geosite category-ads-all block

Служебное:
  /whoami — ваш chat_id (для whitelist)
  /help — эта справка
EOF
}

ss_telegram_status_text() {
  local running mode ver def enabled
  running="нет"
  ss_xray_running 2>/dev/null && running="да"
  mode="${SS_MODE:-proxy}"
  ver="${ADDON_VERSION:-?}"
  def="${SS_DEFAULT_OUTBOUND:-direct}"
  enabled="${SS_ENABLED_OUTBOUNDS:-(нет)}"
  printf 'StealthSurf v%s\nVPN: %s\nРежим: %s\nDefault: %s\nOutbounds: %s\n' \
    "$ver" "$running" "$mode" "$def" "$enabled"
}

ss_telegram_list_text() {
  local body
  if [ ! -f "$SS_CACHE_CONFIGS" ]; then
    echo "Каталог пуст — сначала sync (ssurf sy) или добавьте API-ключ."
    return 0
  fi
  body=$(jq -r --arg en "${SS_ENABLED_OUTBOUNDS:-}" '
    ($en | split(" ") | map(select(length>0))) as $ids |
    [ .[]? | select(. != null) |
      ( (.id|tostring) as $id |
        (if ($ids | index($id)) then "[ON]" else "[  ]" end) +
        " #" + $id + " " + (.protocol // "?") + " " + (.title // "-")
      )
    ] | if length==0 then "Каталог пуст." else ("VPN-конфиги:\n" + join("\n")) end
  ' "$SS_CACHE_CONFIGS" 2>/dev/null) || body="Не удалось прочитать каталог."
  printf '%s\n' "$body"
}

ss_telegram_rules_text() {
  if [ ! -f "$SS_ROUTING_FILE" ]; then
    echo "Правил нет."
    return 0
  fi
  jq -r '
    "Default: " + (.default_outbound // "(не задан)"),
    "",
    ( (.rules // []) |
      if length==0 then "Правил нет."
      else
        to_entries[] |
        "\(.key+1). [\(.value.priority // "?")] \(.value.type // "?") \(.value.matcher // "?") → \(.value.outbound // "?")" +
        (if .value.name then " (\(.value.name))" else "" end)
      end
    )
  ' "$SS_ROUTING_FILE" 2>/dev/null || echo "Не удалось прочитать routing.json"
}

ss_telegram_normalize_outbound() {
  local ob="$1"
  case "$ob" in
  direct | block) printf '%s' "$ob" ;;
  ss-*) printf '%s' "$ob" ;;
  '' | *[!0-9]*)
    echo ""
    return 1
    ;;
  *) printf 'ss-%s' "$ob" ;;
  esac
}

ss_telegram_add_rule() {
  # args: type matcher outbound [name...]
  local typ matcher outbound_raw name outbound rule_json id
  typ="$1"
  matcher="$2"
  outbound_raw="$3"
  shift 3
  name="$*"

  case "$typ" in
  domain | full | keyword | regexp | geosite | geoip | ip | cidr) ;;
  *)
    echo "Неизвестный type «$typ». Допустимо: domain|full|keyword|regexp|geosite|geoip|ip|cidr"
    return 1
    ;;
  esac
  [ -n "$matcher" ] || {
    echo "Нужен matcher"
    return 1
  }
  outbound=$(ss_telegram_normalize_outbound "$outbound_raw") || {
    echo "Неверный outbound «$outbound_raw» (ss-<id>|id|direct|block)"
    return 1
  }
  [ -n "$name" ] || name="${typ}-${matcher}"

  rule_json=$(jq -nc \
    --arg name "$name" \
    --arg type "$typ" \
    --arg matcher "$matcher" \
    --arg outbound "$outbound" \
    '{name:$name, type:$type, matcher:$matcher, outbound:$outbound}') || return 1

  # Validate against current outbounds before write
  case "$outbound" in
  direct | block) ;;
  ss-*)
    id=${outbound#ss-}
    if ! jq -e --argjson id "$id" '(.enabled // []) | index($id) != null' "$SS_OUTBOUNDS_FILE" >/dev/null 2>&1; then
      echo "Outbound $outbound не включён. Сначала enable (или /list)."
      return 1
    fi
    ;;
  esac

  if ! ss_routing_add_rule "$rule_json"; then
    echo "Не удалось добавить правило (валидация)."
    return 1
  fi
  if ! ss_rebuild_and_restart; then
    echo "Правило записано, но rebuild/restart не удался."
    return 1
  fi
  echo "Добавлено: $typ $matcher → $outbound"
  return 0
}

ss_telegram_handle_command() {
  local chat_id="$1"
  local text="$2"
  local cmd args reply

  # Strip bot mention: /cmd@BotName
  text=$(printf '%s' "$text" | sed 's/\r//g' | head -n 1)
  cmd=$(printf '%s' "$text" | awk '{print $1}' | sed 's/@.*//' | tr '[:upper:]' '[:lower:]')
  args=$(printf '%s' "$text" | sed 's/^[^ ]* *//')

  case "$cmd" in
  /start | /help | /помощь)
    ss_telegram_send "$chat_id" "$(ss_telegram_help_text)"
    return 0
    ;;
  /whoami | /chatid)
    ss_telegram_send "$chat_id" "Ваш chat_id: ${chat_id}"$'\n'"Добавьте его в Настройки → Telegram (whitelist)."
    return 0
    ;;
  esac

  if ! ss_telegram_chat_allowed "$chat_id"; then
    ss_telegram_send "$chat_id" "Доступ запрещён. Ваш chat_id: ${chat_id}"$'\n'"Добавьте его в whitelist настроек аддона."
    return 0
  fi

  case "$cmd" in
  /status | /статус | /st)
    reply=$(ss_telegram_status_text)
    ss_telegram_send "$chat_id" "$reply"
    ;;
  /on | /up | /start_vpn | /вкл)
    if ss_start >/tmp/stealthsurf-tg-cmd.out 2>&1; then
      ss_telegram_send "$chat_id" "VPN включён."$'\n'"$(ss_telegram_status_text)"
    else
      ss_telegram_send "$chat_id" "Ошибка включения:"$'\n'"$(tail -n 8 /tmp/stealthsurf-tg-cmd.out 2>/dev/null)"
    fi
    ;;
  /off | /dn | /stop | /выкл)
    if ss_stop >/tmp/stealthsurf-tg-cmd.out 2>&1; then
      ss_telegram_send "$chat_id" "VPN выключен."
    else
      ss_telegram_send "$chat_id" "Ошибка выключения:"$'\n'"$(tail -n 8 /tmp/stealthsurf-tg-cmd.out 2>/dev/null)"
    fi
    ;;
  /restart | /re | /rs | /перезапуск)
    if ss_restart >/tmp/stealthsurf-tg-cmd.out 2>&1; then
      ss_telegram_send "$chat_id" "VPN перезапущен."$'\n'"$(ss_telegram_status_text)"
    else
      ss_telegram_send "$chat_id" "Ошибка перезапуска:"$'\n'"$(tail -n 8 /tmp/stealthsurf-tg-cmd.out 2>/dev/null)"
    fi
    ;;
  /update | /upd | /обновить)
    ss_telegram_send "$chat_id" "Проверяю обновление…"
    if type ss_version_update_if_available >/dev/null 2>&1; then
      ss_version_update_if_available 0 >/tmp/stealthsurf-tg-cmd.out 2>&1
      upd_rc=$?
      case $upd_rc in
      0) ss_telegram_send "$chat_id" "Аддон обновлён."$'\n'"$(tail -n 12 /tmp/stealthsurf-tg-cmd.out 2>/dev/null)" ;;
      2) ss_telegram_send "$chat_id" "Уже актуальная версия (${ADDON_VERSION})." ;;
      *) ss_telegram_send "$chat_id" "Обновление не удалось:"$'\n'"$(tail -n 12 /tmp/stealthsurf-tg-cmd.out 2>/dev/null)" ;;
      esac
    else
      ss_telegram_send "$chat_id" "Функция update недоступна в этой сборке."
    fi
    ;;
  /list | /ls | /список)
    ss_telegram_send "$chat_id" "$(ss_telegram_list_text)"
    ;;
  /rules | /правила)
    ss_telegram_send "$chat_id" "$(ss_telegram_rules_text)"
    ;;
  /ruleadd | /ruleappend | /addrule | /правило)
    # shellcheck disable=SC2086
    set -- $args
    if [ "$#" -lt 3 ]; then
      ss_telegram_send "$chat_id" "Использование: /ruleadd <type> <matcher> <outbound> [name]"
      return 0
    fi
    reply=$(ss_telegram_add_rule "$@" 2>&1)
    ss_telegram_send "$chat_id" "$reply"
    ;;
  *)
    if [ -n "$cmd" ] && printf '%s' "$cmd" | grep -q '^/'; then
      ss_telegram_send "$chat_id" "Неизвестная команда. /help"
    fi
    ;;
  esac
}

ss_telegram_process_updates_json() {
  local json="$1"
  local n i chat_id text update_id next_offset
  [ -n "$json" ] || return 0
  printf '%s' "$json" | jq -e '.ok == true' >/dev/null 2>&1 || return 1

  n=$(printf '%s' "$json" | jq '.result | length' 2>/dev/null || echo 0)
  [ -n "$n" ] && [ "$n" -gt 0 ] 2>/dev/null || return 0

  next_offset=""
  i=0
  while [ "$i" -lt "$n" ]; do
    update_id=$(printf '%s' "$json" | jq -r --argjson i "$i" '.result[$i].update_id // empty')
    chat_id=$(printf '%s' "$json" | jq -r --argjson i "$i" '
      .result[$i].message.chat.id // .result[$i].edited_message.chat.id // empty')
    text=$(printf '%s' "$json" | jq -r --argjson i "$i" '
      .result[$i].message.text // .result[$i].edited_message.text // empty')
    if [ -n "$update_id" ]; then
      next_offset=$((update_id + 1))
    fi
    if [ -n "$chat_id" ] && [ -n "$text" ]; then
      ss_telegram_log "chat=$chat_id text=$(printf '%s' "$text" | head -c 80)"
      ss_telegram_handle_command "$chat_id" "$text"
    fi
    i=$((i + 1))
  done

  if [ -n "$next_offset" ]; then
    ss_ensure_dirs
    printf '%s\n' "$next_offset" >"$SS_TG_OFFSET_FILE"
  fi
  return 0
}

ss_telegram_poll_once() {
  # One getUpdates call (long-poll). Safe for cron or daemon loop.
  local offset json
  ss_telegram_defaults
  [ "$SS_TG_ENABLED" = "1" ] || return 0
  [ -n "$SS_TG_BOT_TOKEN" ] || return 0

  offset=""
  [ -f "$SS_TG_OFFSET_FILE" ] && offset=$(cat "$SS_TG_OFFSET_FILE" 2>/dev/null | head -n 1 | tr -cd '0-9')

  if [ -n "$offset" ]; then
    json=$(ss_telegram_api getUpdates -G \
      --data-urlencode "offset=${offset}" \
      --data-urlencode "timeout=25" \
      --data-urlencode "allowed_updates=[\"message\"]")
  else
    json=$(ss_telegram_api getUpdates -G \
      --data-urlencode "timeout=25" \
      --data-urlencode "allowed_updates=[\"message\"]")
  fi

  [ -n "$json" ] || return 1
  ss_telegram_process_updates_json "$json"
}

ss_telegram_running() {
  local pid
  [ -f "$SS_TG_PIDFILE" ] || return 1
  pid=$(cat "$SS_TG_PIDFILE" 2>/dev/null)
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

ss_telegram_stop_daemon() {
  local pid
  if [ -f "$SS_TG_PIDFILE" ]; then
    pid=$(cat "$SS_TG_PIDFILE" 2>/dev/null)
    if [ -n "$pid" ]; then
      kill "$pid" 2>/dev/null || true
      local w=0
      while kill -0 "$pid" 2>/dev/null && [ "$w" -lt 5 ]; do
        sleep 1
        w=$((w + 1))
      done
      kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$SS_TG_PIDFILE"
  fi
  # Also clear cru tick if present
  if command -v cru >/dev/null 2>&1; then
    cru d stealthsurf_tg 2>/dev/null || true
  fi
}

ss_telegram_daemon_loop() {
  # Background long-poll loop (invoked as: stealthsurf telegram-daemon)
  ss_telegram_defaults
  echo $$ >"$SS_TG_PIDFILE"
  ss_telegram_log "daemon start pid=$$"
  while [ "${SS_TG_ENABLED:-0}" = "1" ] && [ -n "${SS_TG_BOT_TOKEN:-}" ]; do
    ss_telegram_poll_once || sleep 3
    # Re-read conf in case settings changed without kill
    if [ -f "$SS_CONF_FILE" ]; then
      # shellcheck disable=SC1090
      . "$SS_CONF_FILE"
    fi
    ss_telegram_defaults
    [ "${SS_TG_ENABLED:-0}" = "1" ] || break
    [ -n "${SS_TG_BOT_TOKEN:-}" ] || break
  done
  rm -f "$SS_TG_PIDFILE"
  ss_telegram_log "daemon stop"
}

ss_telegram_start_daemon() {
  ss_telegram_defaults
  [ "$SS_TG_ENABLED" = "1" ] || {
    ss_telegram_stop_daemon
    return 0
  }
  [ -n "$SS_TG_BOT_TOKEN" ] || {
    ss_warn "Telegram enabled but bot token empty"
    ss_telegram_stop_daemon
    return 1
  }
  if ss_telegram_running; then
    return 0
  fi
  ss_ensure_dirs
  # Prefer background daemon; fall back to minute cron tick
  if [ -x "$ADDON_SCRIPT" ]; then
    # Detach: nohup + redirect; daemon re-execs addon entry
    (
      # shellcheck disable=SC2086
      nohup "$ADDON_SCRIPT" telegram-daemon >/dev/null 2>&1 &
    ) >/dev/null 2>&1
    sleep 1
    if ss_telegram_running; then
      ss_ok "Telegram bot daemon started"
      ss_activity "telegram.daemon" "started"
      return 0
    fi
  fi
  # Fallback: cru every minute with short poll (timeout still 25 — ok if cron overlaps guarded by lock)
  if command -v cru >/dev/null 2>&1; then
    cru d stealthsurf_tg 2>/dev/null || true
    cru a stealthsurf_tg "* * * * * /jffs/scripts/$ADDON_TAG telegram-tick"
    ss_ok "Telegram bot via cru (minute tick)"
    return 0
  fi
  ss_warn "Could not start Telegram bot daemon"
  return 1
}

ss_telegram_ensure() {
  # Call after settings apply / startup / doctor — always best-effort (never fail settings apply)
  ss_telegram_defaults
  if [ "$SS_TG_ENABLED" = "1" ] && [ -n "$SS_TG_BOT_TOKEN" ]; then
    ss_telegram_start_daemon || ss_warn "Telegram bot not started (will retry on next startup/doctor)"
  else
    ss_telegram_stop_daemon || true
  fi
  return 0
}

ss_telegram_tick() {
  # Cron fallback: single poll under flock
  ss_with_lock telegram ss_telegram_poll_once
}
