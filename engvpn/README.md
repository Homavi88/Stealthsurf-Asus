# EngVPN — аддон для Asuswrt-Merlin

Открытый VPN-аддон для Merlin с панелью, близкой к StealthSurf. Только открытые компоненты (панель на Node / Entware, Xray · sing-box · mihomo, open zapret/nfqws, Cloudflare WARP API). **Не** содержит проприетарных бинарников и торговых марок StealthSurf.

| | |
| --- | --- |
| Версия | **0.4.0** ([`VERSION`](./VERSION)) |
| Панель | `http://<lan_ip>:8790/` (нужен пароль) |
| Префикс установки | `/jffs/addons/engvpn` или `/tmp/mnt/<USB>/engvpn` |
| CLI | `engvpnd` |
| Изоляция | Не трогает SurfGate `:1131`, официальный StealthSurf `:8800` и alfa `:8788` |

Релиз: [engvpn-0.4.0](https://github.com/Homavi88/Stealthsurf-Asus/releases/tag/engvpn-0.4.0) (после публикации)

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

Установщик запросит пароль панели (8–128 символов), скачает пакет под ваш CPU (`merlin-aarch64` / `merlin-armv7`), проверит **SHA-256** и при наличии — **Minisign**, затем запустит сервис.

Без интерактива:

```sh
ENGVPN_PASSWORD='your-password' curl -fsSL https://raw.githubusercontent.com/Homavi88/Stealthsurf-Asus/main/engvpn/merlin.sh | sh
```

| Переменная | Назначение |
| --- | --- |
| `ENGVPN_PREFIX` | Путь установки |
| `ENGVPN_LOCAL_PACKAGE` | Локальный `.tar.gz` |
| `ENGVPN_FEED` | Другой URL ленты |

Панель: `http://192.168.50.1:8790/` (подставьте LAN IP).

## Аккаунт: API-ключ или URL подписки

В **Настройки → Аккаунт** (одно меню):

1. **Основной путь** — ключ StealthSurf HTTP API (`Authorization: Bearer stlth_…`). Документация: https://docs.stealthsurf.net/api  
   EngVPN вызывает `GET /profile` и `GET /configs`, импортирует `connection_url` в локальный список.  
2. **Если ключ пуст / неактивен** — на том же экране поля **URL подписки** или одиночный `vless://` / `trojan://` / `ss://`.

Ключ хранится только на роутере (`data/account.json`, mode 0600). Проприетарные бинарники StealthSurf не скачиваются.

## Панель 0.4.0

UI по карте экранов StealthSurf, бренд **EngVPN**, русский интерфейс:

- **Главная** — статус, IP, нагрузка, скорость, локации  
- **Роутер** — transparent (все / выбранные / кроме), метод **auto / TPROXY / REDIRECT**, устройства, DNS/QUIC/kill-switch/IPv6, реклама, «О роутере»  
- **Сеть** — YouTube/Discord через **open zapret/nfqws** (DPI)  
- **Подключение** — Cloudflare WARP (открытая регистрация) + GRE  
- **Движок** — Xray / **Ferrum-слот (открытый Xray Reality)** / sing-box / mihomo  

## Повседневные команды

```sh
engvpnd status
engvpnd transparent status
engvpnd transparent apply          # method=auto → TPROXY+UDP если xt_TPROXY есть
engvpnd dpi apply                  # open nfqws
engvpnd warp create                # Cloudflare WARP профиль
engvpnd update-check
engvpnd update                     # SHA-256 + Minisign
```

### Transparent / UDP

В `data/transparent.conf`:

```ini
mode=all
method=auto        # auto | tproxy | redirect
port=12345
killswitch=0
```

- **TPROXY** — TCP+UDP при наличии `xt_TPROXY` / `xt_socket`  
- **REDIRECT** — только TCP (fallback на многих сборках Merlin)  
- Dokodemo inbound с `followRedirect` / `tproxy` пишется в `data/run/dokodemo.inbound.json`

Подробнее: документация hard-parity в Project store.

### Minisign

Публичный ключ: [`keys/engvpn.minisign.pub`](./keys/engvpn.minisign.pub) и `keys/README.md`.  
Проверка: `minisign -Vm package.tar.gz -p keys/engvpn.minisign.pub` или `verify-minisign.mjs` на роутере.

## Удаление

```sh
sh /jffs/addons/engvpn/share/engvpn/install.sh uninstall
```

## Сборка / smoke

```sh
cd engvpn
./build-package.sh      # подписывает пакеты, если есть keys/engvpn.minisign.key
./smoke-test.sh
./publish-release.sh --push
```

## Отличия от официального StealthSurf

| Upstream | EngVPN 0.4 |
| --- | --- |
| Закрытый routerd / nfqws / Ferrum | Open Node + zapret/nfqws + Xray в слоте Ferrum |
| Облако / баланс только в приложении | Публичный API с вашим ключом + URL подписки |
| WARP закрытый стек | Cloudflare client API → WireGuard |
| Только SHA в части сборок | SHA-256 + Minisign |
| Статический демон без Entware | **Entware Node** (осознанно) |
