# Установка StealthSurf UI (Asuswrt-Merlin)

Версия пакета: **v1.0.27** (GitHub Releases).

## Требования

- Asuswrt-Merlin `384.15+` / `3006.102.1+`
- **Administration → System → Enable JFFS custom scripts and configs = Yes** (и reboot при первом включении)
- **Entware уже установлен** через `amtm` (должен существовать `/opt` и `opkg`)

## One-liner (рекомендуется)

По SSH на роутере (цветной баннер + шаги в терминале):

```sh
curl -fsSL https://raw.githubusercontent.com/Homavi88/Stealthsurf-Asus/main/install.sh | sh
```

Без цвета: `NO_COLOR=1 curl -fsSL …/install.sh | sh`

Установщик:

1. Проверяет JFFS + Entware  
2. Ставит зависимости через `opkg` (`curl`, `jq`, `ca-certificates`, `unzip`, …)  
3. Качает `asuswrt-merlin-stealthsurf.tar.gz` из **GitHub Releases** (`latest`), fallback — `packaged/` в репозитории  
4. Кладёт скрипт в `/jffs/scripts/stealthsurf`, UI в `/jffs/addons/stealthsurf`  
5. Вешает хуки Merlin, cron autosync/watchdog, symlink’и `stealthsurf` и **`ssurf`**  
6. При необходимости скачивает Xray  

## Где открыть в WebUI

1. Выйти из админки роутера и зайти снова  
2. Меню: **VPN → StealthSurf**  
3. Прямой URL (если других user-аддонов нет): `http://<IP-роутера>/user1.asp`  
   (иначе `user2.asp`…`user20.asp` — первый свободный слот)  
4. JSON/логи UI: `http://<IP-роутера>/ext/stealthsurf/…`

Страница использует нативную оболочку Asuswrt-Merlin (боковое меню, вкладки VPN,
`FormTitle` / `FormTable`, кнопки `button_gen`) — тот же подход, что у XrayUI.

## Пути на роутере

| Что | Путь |
| --- | --- |
| CLI | `/jffs/scripts/stealthsurf`, `/opt/bin/ssurf`, `/opt/bin/stealthsurf` |
| UI (файлы) | `/jffs/addons/stealthsurf/` |
| Web | `/www/user/stealthsurf/` |
| Данные / кэш | `/opt/share/stealthsurf/` |
| Конфиг аддона | `/opt/etc/stealthsurf.conf` |
| Xray config | `/opt/etc/xray/stealthsurf.json` |

## Быстрый старт после установки

```sh
ssurf key 'stlth_…'     # API-ключ с сайта StealthSurf
ssurf sy                # sync каталога
ssurf ls                # список конфигов
ssurf ap <id>           # apply как sole outbound
ssurf mode redirect
ssurf up                # старт
ssurf st                # статус
```

В WebUI: ключ → **Синхронизировать** → enable outbounds / default → режим **redirect** → **Старт**.

Проверка: телефон в Wi‑Fi **без** системного VPN → внешний IP = IP ноды StealthSurf.

Справка CLI: `ssurf h` · меню: `ssurf m` · подробно: [CLI.md](./CLI.md).

## Бинарники протоколов

| Runtime | Как появляется |
| --- | --- |
| **Xray** (VLESS/Trojan/SS/OpenFlux/WG/HTTP/SOCKS) | `ssurf xray` / авто при install |
| **Hysteria2** | автоскачивание при Apply hy2-конфига |
| **AmneziaWG** | вручную на роутере (`awg-quick`) — ядро, не zip |

Geodata (routing): `ssurf geo`.

## Обновление

```sh
ssurf cu          # check-update
ssurf upd         # поставить, если новее
ssurf upd -f      # всегда latest с GitHub
```

В UI: **Проверить версию** / баннер обновления.

## Удаление

```sh
ssurf un --yes
# или: stealthsurf uninstall --yes
```

Нужен явный `--yes` (алиас `rm` убран — слишком легко снести аддон).  
Чистит iptables/ip rule, хуки, cron, UI, данные. Бинарь Xray в `/opt` не трогается (может быть общим).

Если вкладка или `ssurf` пропали после сбоя/обновления — сначала восстановление:

```sh
/jffs/scripts/stealthsurf doctor
# затем выйти/войти в WebUI
```

## Smoke после reboot

1. UI снова в **VPN → StealthSurf**  
2. При желаемом автостарте VPN поднимается сам  
3. `ssurf st` → `running: true` (если был desired)  
4. `ssurf dn` → интернет напрямую  

Чеклист: [VERIFICATION_CHECKLIST.md](./VERIFICATION_CHECKLIST.md).
