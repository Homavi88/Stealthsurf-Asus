# StealthSurf Alfa

Отдельный аддон панели роутера. Повторяет экраны и меню со снимка в [`alfa/`](../alfa/), слушает порт **8788** и не занимает SurfGate (`:1131`) и официальный StealthSurf (`:8800`).

| | |
| --- | --- |
| Версия | `0.1.0-alpha` |
| Панель | `http://<IP_роутера>:8788/` |
| Пароль первого входа | `alfa` |
| Каталог на роутере | `/jffs/addons/alfa` |
| Служба | `/jffs/scripts/alfa` |
| Состояние | `/jffs/addons/alfa/data/` |
| Журнал сборки | [`ALPHA.md`](./ALPHA.md) |

Это альфа: панель и ядра уже работают, прозрачный перехват всей LAN через iptables/TPROXY ещё впереди. Пока устройства ходят в SOCKS/HTTP альфы или панель смотрит локальный контур.

## Что нужно на роутере

1. Asuswrt-Merlin с включёнными JFFS custom scripts.
2. Entware через `amtm` (`/opt/bin/opkg`).
3. Node.js 18+ из Entware (`node`).
4. Свободный порт **8788**.
5. Для ядер на ARM-роутере — сборки `linux-arm64` / `linux-aarch64`. Панель умеет скачать Xray, sing-box и mihomo сама; Ferrum кладётся вручную в `data/cores/ferrum`.

Не ставьте альфу поверх `/jffs/addons/ssurf` или `/jffs/addons/stealthsurf`. У неё свой каталог `/jffs/addons/alfa`.

## Установка

На роутере по SSH:

```sh
# 1) Node, если ещё нет
/opt/bin/opkg update
/opt/bin/opkg install node

# 2) Каталог аддона
mkdir -p /jffs/addons/alfa
cd /tmp
/opt/bin/curl -fsSL -o alfa-addon.tgz \
  "https://github.com/Homavi88/Stealthsurf-Asus/archive/refs/heads/main.tar.gz"
tar -xzf alfa-addon.tgz
cp -a Stealthsurf-Asus-main/alfa-addon/. /jffs/addons/alfa/
rm -rf Stealthsurf-Asus-main alfa-addon.tgz

# 3) Скрипт службы
cat > /jffs/scripts/alfa << 'EOF'
#!/bin/sh
# StealthSurf Alfa — панель :8788
export PATH="/opt/bin:/opt/sbin:/usr/sbin:/usr/bin:/sbin:/bin"
ADDON_DIR="/jffs/addons/alfa"
PID_FILE="/var/run/alfa.pid"
LOG_FILE="/tmp/alfa-panel.log"

start() {
  if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo "alfa already running pid $(cat "$PID_FILE")"
    return 0
  fi
  cd "$ADDON_DIR" || exit 1
  mkdir -p "$ADDON_DIR/data"
  nohup node server.mjs >>"$LOG_FILE" 2>&1 &
  echo $! > "$PID_FILE"
  echo "alfa started on :8788 (pid $(cat "$PID_FILE"))"
}

stop() {
  if [ -f "$PID_FILE" ]; then
    kill "$(cat "$PID_FILE")" 2>/dev/null || true
    rm -f "$PID_FILE"
  fi
  # только процесс панели альфы, другие node не трогаем
  for pid in $(ps w | awk '/[s]erver\.mjs/ && /\/jffs\/addons\/alfa\// {print $1}'); do
    kill "$pid" 2>/dev/null || true
  done
  echo "alfa stopped"
}

status() {
  if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo "running pid $(cat "$PID_FILE")"
  else
    echo "stopped"
  fi
}

case "$1" in
  start) start ;;
  stop) stop ;;
  restart) stop; start ;;
  status) status ;;
  *) echo "usage: $0 {start|stop|restart|status}"; exit 1 ;;
esac
EOF
chmod +x /jffs/scripts/alfa

# 4) Автозапуск после монтирования диска
touch /jffs/scripts/post-mount
chmod +x /jffs/scripts/post-mount
grep -q 'scripts/alfa start' /jffs/scripts/post-mount 2>/dev/null \
  || echo '/jffs/scripts/alfa start #alfa' >> /jffs/scripts/post-mount

# 5) Запуск сейчас
/jffs/scripts/alfa start
```

Откройте панель:

```text
http://192.168.50.1:8788/
```

Подставьте свой LAN IP. Логин: пароль `alfa` (смените в разделе «Прочее» после входа).

### Обновление

Повторите шаги копирования из репозитория, затем:

```sh
/jffs/scripts/alfa restart
```

Каталог `data/` не перезаписывайте: там пароль, сессии, подписки и скачанные ядра.

### Проверка

```sh
/jffs/scripts/alfa status
/opt/bin/curl -fsS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8788/
tail -n 50 /tmp/alfa-panel.log
```

Код `200` значит, что панель отвечает. Ядра скачиваются из раздела «Движок» в интерфейсе.

## Удаление

Удаление снимает только альфу. SurfGate (`ssurf`, `:1131`) и официальный StealthSurf (`stealthsurf`, `:8800`) не трогаются.

```sh
# 1) Остановить панель
/jffs/scripts/alfa stop 2>/dev/null || true

# 2) Убрать автозапуск
if [ -f /jffs/scripts/post-mount ]; then
  sed -i '/#alfa/d' /jffs/scripts/post-mount
  sed -i '/\/jffs\/scripts\/alfa /d' /jffs/scripts/post-mount
fi

# 3) Удалить службу и файлы аддона
rm -f /jffs/scripts/alfa /var/run/alfa.pid /tmp/alfa-panel.log
rm -rf /jffs/addons/alfa

# 4) Проверить, что чужие аддоны на месте
ls /jffs/addons
# ожидаются, если стояли раньше: ssurf  и/или  stealthsurf
# каталога alfa быть не должно
```

Если нужно сохранить настройки на потом, перед удалением скопируйте `/jffs/addons/alfa/data` куда-нибудь ещё. После `rm -rf` пароль, подписки и ядра с роутера исчезнут.

## Что альфа не трогает

| Путь / порт | Чей |
| --- | --- |
| `/jffs/addons/ssurf`, `:1131` | SurfGate |
| `/jffs/addons/stealthsurf`, `:8800` | Официальный StealthSurf |
| `/opt/etc/xray/ssurf`, `/opt/etc/ssurf.conf` | SurfGate |
| `/jffs/addons/alfa`, `:8788` | Эта альфа |

Не вызывайте `surfgate un` и не чистите `/jffs/addons/stealthsurf`, если хотите убрать только альфу.

## Локальный запуск без роутера

На машине с Node 18+:

```sh
cd alfa-addon
node server.mjs
```

Тесты: `node --test --test-concurrency=1 test/smoke.mjs`.

Подробности реализации и ограничения — в [`ALPHA.md`](./ALPHA.md).
