# EngVPN — аддон для Asuswrt-Merlin

Открытый VPN-аддон для Merlin с панелью, близкой к StealthSurf. Только открытые компоненты (панель на Node / Entware, Xray · sing-box · mihomo, open zapret/nfqws, Cloudflare WARP API). **Не** содержит проприетарных бинарников и торговых марок StealthSurf.

| | |
| --- | --- |
| Версия | **0.5.0** ([`VERSION`](./VERSION)) |
| Панель | `http://<lan_ip>:8790/` (нужен пароль) |
| Префикс установки | `/jffs/addons/engvpn` или `/tmp/mnt/<USB>/engvpn` |
| CLI | `engvpnd` |
| Изоляция | Не трогает SurfGate `:1131`, официальный StealthSurf `:8800` и alfa `:8788` |

Релиз: после публикации — `engvpn-0.5.0` в GitHub Releases.

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

| Переменная | Назначение |
| --- | --- |
| `ENGVPN_PREFIX` | Путь установки |
| `ENGVPN_LOCAL_PACKAGE` | Локальный `.tar.gz` |
| `ENGVPN_FEED` | Другой URL ленты |
| `ENGVPN_SKIP_BACKUP=1` | Не создавать резервную копию перед install/upgrade |
| `ENGVPN_RESTORE=1\|0` | На uninstall: восстановить из бэкапа (1) или полное удаление (0) |
| `ENGVPN_BACKUP_DIR` | Каталог бэкапов (по умолчанию рядом с prefix: `…/addons/.engvpn-backup`) |

Панель: `http://192.168.50.1:8790/` (подставьте LAN IP).

## Резервная копия и восстановление

Перед **install** и **upgrade** EngVPN пишет снимок в каталог `.engvpn-backup` рядом с префиксом (например `/jffs/addons/.engvpn-backup/`):

- дерево `data/` (state, account, transparent, DPI, WARP, SmartDNS, устройства);
- файлы пакета по манифесту (`sbin/engvpnd`, `share/engvpn/…`), чтобы можно было откатиться.

На **uninstall**:

1. Останавливается сервис, снимается свежий бэкап (если не `ENGVPN_SKIP_BACKUP=1`).  
2. Скрипт спрашивает: *«Восстановить EngVPN из резервной копии (откат)?»*  
   - **да** (`ENGVPN_RESTORE=1`) — распаковать последний бэкап в prefix, вернуть хуки, запустить сервис (uninstall отменяется → откат);  
   - **нет** (`ENGVPN_RESTORE=0`) — удалить prefix; каталог `.engvpn-backup` остаётся для ручного восстановления.

CLI:

```sh
engvpnd backup create
engvpnd backup latest
engvpnd backup restore
engvpnd backup list
```

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

## Повседневные команды

```sh
engvpnd status
engvpnd transparent status
engvpnd transparent apply
engvpnd discover                 # LAN JSONL
engvpnd smartdns apply           # bypass list → routing + iptables
engvpnd dpi apply
engvpnd warp create
engvpnd backup create
engvpnd update-check
engvpnd update
```

### Transparent / UDP

В `data/transparent.conf`:

```ini
mode=all
method=auto        # auto | tproxy | redirect
port=12345
killswitch=0
```

### SmartDNS (обход)

`data/smartdns.conf` + `data/smartdns-bypass.txt` (домен, IP или CIDR на строку).  
При `enabled=1`: IP/CIDR → `RETURN` в цепочке ENGVPN; домены → `data/run/bypass.routing.json` (outbound `direct`).

### Minisign

Публичный ключ: [`keys/engvpn.minisign.pub`](./keys/engvpn.minisign.pub).

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
