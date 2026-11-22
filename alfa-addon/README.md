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

## Установка одной командой

На роутере по SSH (нужны Merlin, JFFS custom scripts и Entware через `amtm`):

```sh
/opt/bin/curl -fsSL https://raw.githubusercontent.com/Homavi88/Stealthsurf-Asus/main/alfa-addon/install.sh | sh
```

Скрипт сам:

1. проверит JFFS и Entware;
2. поставит Node.js из Entware, если его ещё нет;
3. скачает `alfa-addon` и положит в `/jffs/addons/alfa`;
4. установит службу `/jffs/scripts/alfa` и автозапуск в `post-mount`;
5. запустит панель на порту **8788**.

При обновлении той же командой каталог `data/` (пароль, подписки, ядра) сохраняется.

Откройте:

```text
http://192.168.50.1:8788/
```

Подставьте свой LAN IP. Пароль: `alfa`.

### Управление

```sh
/jffs/scripts/alfa status
/jffs/scripts/alfa restart
/jffs/scripts/alfa stop
```

Ядра Xray / sing-box / mihomo скачиваются в панели: **Движок**. На ARM-роутере берутся сборки `arm64` / `armv7`.

## Удаление одной командой

```sh
/opt/bin/curl -fsSL https://raw.githubusercontent.com/Homavi88/Stealthsurf-Asus/main/alfa-addon/install.sh | sh -s -- uninstall
```

Или уже после установки:

```sh
/jffs/scripts/alfa uninstall
```

Удаляется только альфа. SurfGate (`/jffs/addons/ssurf`, `:1131`) и официальный StealthSurf (`/jffs/addons/stealthsurf`, `:8800`) не трогаются.

Если настройки нужны потом — перед удалением скопируйте `/jffs/addons/alfa/data`.

## Что нужно на роутере

1. Asuswrt-Merlin с JFFS custom scripts.
2. Entware (`amtm`).
3. Свободный порт **8788**.
4. HTTPS-клиент Entware (`curl`) — им ставится аддон.

Не ставьте альфу поверх `/jffs/addons/ssurf` или `/jffs/addons/stealthsurf`. У неё свой каталог `/jffs/addons/alfa`.

## Что альфа не трогает

| Путь / порт | Чей |
| --- | --- |
| `/jffs/addons/ssurf`, `:1131` | SurfGate |
| `/jffs/addons/stealthsurf`, `:8800` | Официальный StealthSurf |
| `/opt/etc/xray/ssurf`, `/opt/etc/ssurf.conf` | SurfGate |
| `/jffs/addons/alfa`, `:8788` | Эта альфа |

## Локальный запуск без роутера

```sh
cd alfa-addon
node server.mjs
```

Тесты: `node --test --test-concurrency=1 test/smoke.mjs`.

Подробности реализации — в [`ALPHA.md`](./ALPHA.md).
