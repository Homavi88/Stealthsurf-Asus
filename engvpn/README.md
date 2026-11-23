# EngVPN — аддон для Asuswrt-Merlin

Открытый VPN-аддон для Merlin с панелью, близкой к StealthSurf. Только открытые компоненты (панель на Node / Entware, Xray · sing-box · mihomo, open zapret/nfqws, Cloudflare WARP API). **Не** содержит проприетарных бинарников и торговых марок StealthSurf.

| | |
| --- | --- |
| Версия | **0.5.0** ([`VERSION`](./VERSION)) |
| Панель | `http://<lan_ip>:8790/` (нужен пароль) |
| Префикс установки | `/jffs/addons/engvpn` или `/tmp/mnt/<USB>/engvpn` |
| CLI | `engvpnd` |
| Изоляция | Не трогает SurfGate `:1131`, официальный StealthSurf `:8800` и alfa `:8788` |

Релиз: [engvpn-0.5.0](https://github.com/Homavi88/Stealthsurf-Asus/releases/tag/engvpn-0.5.0)

---

## Требования

1. **Asuswrt-Merlin** с включёнными пользовательскими скриптами JFFS  
2. **Entware** (`amtm`) и **Node.js**: `opkg update && opkg install node`  
3. Root-доступ по SSH и HTTPS-клиент (`curl`)  
4. Достаточно места на JFFS (или USB с ext2/3/4)

## Установка

```sh
curl -fsSL https://raw.githubusercontent.com/Homavi88/Stealthsurf-Asus/main/engvpn/merlin.sh | sh
```

Установщик запросит пароль панели (8–128 символов), **создаст резервную копию** текущего состояния (если уже стоял EngVPN), скачает пакет, проверит **SHA-256** и при наличии — **Minisign**, затем запустит сервис.

Без интерактива:

```sh
ENGVPN_PASSWORD='your-password' curl -fsSL https://raw.githubusercontent.com/Homavi88/Stealthsurf-Asus/main/engvpn/merlin.sh | sh
```

Переменные установщика (`merlin.sh`) и связанных скриптов — в разделе [CLI](#cli) ниже. Панель: `http://192.168.50.1:8790/` (подставьте LAN IP).

## Резервная копия и восстановление

Перед **install** и **upgrade** EngVPN пишет снимок в каталог `.engvpn-backup` рядом с префиксом (например `/jffs/addons/.engvpn-backup/`):

- дерево `data/` (state, account, transparent, DPI, WARP, SmartDNS, устройства);
- файлы пакета по манифесту (`sbin/engvpnd`, `share/engvpn/…`), чтобы можно было откатиться.

На **uninstall**:

1. Останавливается сервис, снимается свежий бэкап (если не `ENGVPN_SKIP_BACKUP=1`).  
2. Скрипт спрашивает: *«Восстановить EngVPN из резервной копии (откат)?»*  
   - **да** (`ENGVPN_RESTORE=1`) — распаковать последний бэкап в prefix, вернуть хуки, запустить сервис (uninstall отменяется → откат);  
   - **нет** (`ENGVPN_RESTORE=0`) — удалить prefix; каталог `.engvpn-backup` остаётся для ручного восстановления.

Команды: `engvpnd backup …` — см. [CLI → backup](#engvpnd-backup).

## Аккаунт: API-ключ или URL подписки

В **Настройки → Аккаунт** (одно меню):

1. **Основной путь** — ключ StealthSurf HTTP API (`Authorization: Bearer stlth_…`). Документация: https://docs.stealthsurf.net/api  
2. **Если ключ пуст / неактивен** — на том же экране поля **URL подписки** или одиночный `vless://` / `trojan://` / `ss://`.

Ключ хранится только на роутере (`data/account.json`, mode 0600).

## Панель 0.5.0

UI по карте экранов StealthSurf, бренд **EngVPN**, русский интерфейс:

- **Главная** — статус, IP, нагрузка, скорость, локации  
- **Роутер** — transparent, устройства из **ARP / ip neigh / dnsmasq leases** (не демо-список), DNS/QUIC/kill-switch  
- **Сеть** — zapret/nfqws + **SmartDNS** (локальный список доменов/IP мимо VPN)  
- **Подключение** — Cloudflare WARP + GRE  
- **Движок** — Xray / Ferrum-слот (открытый Xray Reality) / sing-box / mihomo  

Конфиги на диске (кратко):

| Файл | Назначение |
| --- | --- |
| `data/transparent.conf` | `mode=off\|all\|selected\|exclude`, `method=auto\|tproxy\|redirect`, `port`, `killswitch` |
| `data/devices.select` | IP или MAC (по одному на строку) для selected/exclude |
| `data/dpi.conf` | `enabled`, `queue`, `youtube`, `discord`, `mode=nfqws\|fake` |
| `data/warp.conf` / `warp.profile.ini` | режим WARP и профиль WireGuard |
| `data/gre.conf` | опциональный GRE (`gre_enabled`, remote/local) |
| `data/smartdns.conf` + `smartdns-bypass.txt` | обход VPN по домену/IP/CIDR |

Публичный ключ Minisign: [`keys/engvpn.minisign.pub`](./keys/engvpn.minisign.pub).

---

## CLI

Основная точка входа после установки — **`engvpnd`** (`/jffs/addons/engvpn/sbin/engvpnd` или `$PREFIX/sbin/engvpnd`).  
Большинство подкоманд вызывают скрипты из `$PREFIX/share/engvpn/`. Глобальный флаг:

```sh
engvpnd --data-dir /path/to/data <команда>
engvpnd --help
```

### Сводка `engvpnd`

| Команда | Назначение |
| --- | --- |
| `serve` | Панель в foreground (`node …/run.mjs`) |
| `set-password` | Пароль панели со stdin → pbkdf2 в `data/` |
| `status` | Панель + transparent |
| `stop` | Остановить процесс панели |
| `version` | Версия пакета |
| `update-check` / `update` | Сверка / самообновление из feed |
| `transparent …` | Прозрачный / выборочный VPN |
| `dpi …` | zapret/nfqws (NFQUEUE) |
| `warp …` | Cloudflare WARP + GRE |
| `backup …` | Снимок / откат |
| `smartdns …` | Обход доменов/IP |
| `discover` | Устройства LAN (JSONL) |
| `reconnect` | Transparent (+dpi/smartdns) + restart сервиса |
| `cleanup` | Снять transparent/dpi/smartdns/GRE и `/tmp/engvpn*` |
| `watchdog` | Проверка панели и восстановление правил |

Примеры повседневного использования:

```sh
engvpnd status
engvpnd version
engvpnd transparent status
engvpnd transparent apply
engvpnd discover
engvpnd smartdns apply
engvpnd dpi apply
engvpnd warp create
engvpnd backup create
engvpnd update-check
engvpnd update
engvpnd reconnect
engvpnd cleanup
engvpnd watchdog
```

### Панель и пароль

```sh
engvpnd serve [--data-dir DIR]          # обычно через service.sh, не вручную
echo 'secret-pass' | engvpnd set-password
engvpnd status
engvpnd stop
```

### Обновление

```sh
engvpnd update-check                    # installed=… feed=… update_available=0|1
engvpnd update                          # скачать feed, SHA-256 (+ minisig), upgrade
engvpnd update 90                       # ждать старт сервиса до 90 с (по умолчанию 60)
```

Переменные: `ENGVPN_FEED`, `ENGVPN_PACKAGE_PREFIX`, `ENGVPN_FORCE_UPDATE=1`.

### Transparent

```sh
engvpnd transparent status
engvpnd transparent dry-run
engvpnd transparent apply               # то же, что start
engvpnd transparent start
engvpnd transparent stop
engvpnd transparent write-state         # только state-файл для replay
```

Конфиг: `data/transparent.conf` (`mode`, `method=auto|tproxy|redirect|prefer-tproxy`, `port`, `mark`, `table`, `killswitch`, `lan_if`, `lan_cidr`) + `data/devices.select`.

### DPI (zapret / nfqws)

```sh
engvpnd dpi status
engvpnd dpi dry-run
engvpnd dpi install                     # скачать nfqws при отсутствии
engvpnd dpi apply                       # то же, что start
engvpnd dpi start
engvpnd dpi stop
```

Конфиг: `data/dpi.conf`. Зеркало бинарника: `ENGVPN_ZAPRET_URL`.

### WARP / GRE

```sh
engvpnd warp status
engvpnd warp dry-run
engvpnd warp create                     # регистрация Cloudflare → warp.profile.ini
engvpnd warp import-file /path/to.ini
engvpnd warp gre-up
engvpnd warp gre-down
```

### Backup

```sh
engvpnd backup create
engvpnd backup list
engvpnd backup latest                   # путь к последнему архиву
engvpnd backup path                     # каталог бэкапов
engvpnd backup restore                  # восстановить latest в prefix
```

Переменные: `ENGVPN_SKIP_BACKUP=1`, `ENGVPN_BACKUP_DIR`.

### SmartDNS

```sh
engvpnd smartdns status
engvpnd smartdns dry-run
engvpnd smartdns write                 # только артефакты routing без iptables
engvpnd smartdns apply
engvpnd smartdns stop
```

При `enabled=1`: IP/CIDR → `RETURN` в цепочке `ENGVPN`; домены → `data/run/bypass.routing.json`.

### Discover

```sh
engvpnd discover                        # JSONL: ip, mac, name, online
engvpnd discover /tmp/devices.jsonl     # опциональный путь вывода
```

Источники: ARP, `ip neigh`, dnsmasq leases, nvram clientlist.

### Сервис панели

```sh
sh /jffs/addons/engvpn/share/engvpn/service.sh start
sh /jffs/addons/engvpn/share/engvpn/service.sh stop
sh /jffs/addons/engvpn/share/engvpn/service.sh restart
sh /jffs/addons/engvpn/share/engvpn/service.sh check    # status — синоним
```

Порт панели: `ENGVPN_PORT` (по умолчанию `8790`). Лог: `/tmp/engvpn/engvpnd.log`.

### Установка / удаление (`install.sh`)

Вызывается из `merlin.sh` и `update.sh`; вручную:

```sh
sh …/share/engvpn/install.sh install <archive.tar.gz> <prefix>
sh …/share/engvpn/install.sh upgrade <archive> <version> <wait> <prefix>
sh …/share/engvpn/install.sh uninstall [<prefix>]
```

Удаление:

```sh
sh /jffs/addons/engvpn/share/engvpn/install.sh uninstall
ENGVPN_RESTORE=0 sh /jffs/addons/engvpn/share/engvpn/install.sh uninstall   # без отката
ENGVPN_RESTORE=1 sh /jffs/addons/engvpn/share/engvpn/install.sh uninstall   # откат из бэкапа
```

### Установщик с роутера (`merlin.sh`)

```sh
curl -fsSL …/engvpn/merlin.sh | sh
ENGVPN_PASSWORD='…' curl -fsSL …/engvpn/merlin.sh | sh
ENGVPN_LOCAL_PACKAGE=/tmp/engvpn.tar.gz ENGVPN_PASSWORD='…' sh merlin.sh
```

### Netfilter / хуки Merlin

Внутренние хелперы (обычно не нужны вручную — их зовут `hook.sh` и `watchdog`):

```sh
sh …/share/engvpn/netfilter.sh ensure-port
sh …/share/engvpn/netfilter.sh replay
sh …/share/engvpn/netfilter.sh set-hold 120
```

`hook.sh` цепляется к `services-start`, `services-stop`, `post-mount`, `unmount`, `firewall-start`, `nat-start` (автостарт сервиса и replay правил после пересборки iptables).

### Переменные окружения

| Переменная | Где | Назначение |
| --- | --- | --- |
| `ENGVPN_PASSWORD` | merlin.sh | Пароль панели без TTY |
| `ENGVPN_PREFIX` | merlin.sh | Каталог установки |
| `ENGVPN_LOCAL_PACKAGE` | merlin.sh | Локальный `.tar.gz` |
| `ENGVPN_LOCAL_VERSION` | merlin.sh | Метка версии для локального пакета |
| `ENGVPN_FEED` | merlin / update | URL `latest.json` |
| `ENGVPN_PACKAGE_PREFIX` | merlin / update | Префикс URL релизов |
| `ENGVPN_MINISIGN_PUB` | merlin.sh | URL/путь публичного ключа |
| `ENGVPN_SKIP_BACKUP` | install / backup | `1` — не писать бэкап |
| `ENGVPN_RESTORE` | uninstall | `1` откат / `0` чистое удаление |
| `ENGVPN_BACKUP_DIR` | backup | Каталог снимков |
| `ENGVPN_PORT` | engvpnd / service | Порт панели (8790) |
| `ENGVPN_DATA_DIR` | engvpnd / скрипты | Каталог `data/` |
| `ENGVPN_NODE` | engvpnd | Явный путь к Node |
| `ENGVPN_FORCE_UPDATE` | update | Обновить даже при той же версии |
| `ENGVPN_ZAPRET_URL` | dpi | URL архива zapret/nfqws |

---

## Удаление

```sh
sh /jffs/addons/engvpn/share/engvpn/install.sh uninstall
# или без вопросов:
ENGVPN_RESTORE=0 sh /jffs/addons/engvpn/share/engvpn/install.sh uninstall
```

## Сборка / smoke

```sh
cd engvpn
./build-package.sh
./smoke-test.sh
./publish-release.sh --push
```

## Отличия от официального StealthSurf

| Upstream | EngVPN 0.5 |
| --- | --- |
| Закрытый routerd / nfqws / Ferrum | Open Node + zapret/nfqws + Xray в слоте Ferrum |
| Облако / баланс только в приложении | Публичный API с вашим ключом + URL подписки |
| SmartDNS консоли SS | Локальный список доменов/IP → routing/iptables |
| WARP закрытый стек | Cloudflare client API → WireGuard |
| Только SHA в части сборок | SHA-256 + Minisign |
| Статический демон без Entware | **Entware Node** (осознанно) |
