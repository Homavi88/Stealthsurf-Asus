# EngVPN — аддон для Asuswrt-Merlin

Открытый VPN-аддон для Merlin с панелью, близкой к StealthSurf. **С 1.0.0 панель — статический бинарь на Rust** (`engvpn-daemon`, без Node/V8). Ядра: Xray · Ferrum (open Xray) · sing-box · mihomo; transparent / DPI (zapret/nfqws) / WARP — shell-скрипты. **Не** содержит проприетарных бинарников StealthSurf.

| | |
| --- | --- |
| Версия | **1.0.0** ([`VERSION`](./VERSION)) |
| Панель | `http://<lan_ip>:8790/` (Rust `engvpn-daemon`) |
| Префикс | `/jffs/addons/engvpn` или `/tmp/mnt/<USB>/engvpn` |
| CLI | `engvpnd` (`start` / `stop` / `restart` / `off` / `update` / `status` / `ver` …) |
| Runtime | **без Node**; musl aarch64 предпочтительно (RT-BE88U) |

Релиз: [engvpn-1.0.0](https://github.com/Homavi88/Stealthsurf-Asus/releases/tag/engvpn-1.0.0) (после публикации feed)

Старый Node-стек: [`archive/`](./archive/README.md).

---

## Требования

1. **Asuswrt-Merlin** с пользовательскими скриптами JFFS  
2. **Entware** (`amtm`) — для `curl`/утилит (Node **не** нужен)  
3. Root SSH и HTTPS-клиент (`curl`)  
4. Место и ОЗУ (пороги `merlin.sh`): ≥256 МБ ОЗУ; ≥20 МБ свободно (новая установка); USB только **ext2/3/4**

Предпочтительно JFFS (`/jffs/addons/engvpn`); USB — `/tmp/mnt/<имя>/engvpn`.

## Установка

```sh
curl -fsSL https://raw.githubusercontent.com/Homavi88/Stealthsurf-Asus/main/engvpn/merlin.sh | sh
```

Интерактивно: куда ставить (JFFS/USB) → пароль панели → SHA-256 / Minisign → запуск.

Без интерактива:

```sh
ENGVPN_PASSWORD='…' curl -fsSL …/merlin.sh | sh
ENGVPN_OPEN_PANEL=1 ENGVPN_PREFIX=/jffs/addons/engvpn curl -fsSL …/merlin.sh | sh
```

Панель: `http://192.168.50.1:8790/`.

## Обновление / выключение

```sh
engvpnd check          # сверка с feed
engvpnd update         # = up; SHA-256 (+ minisig), без Node
engvpnd off            # полностью выключить (хуки не поднимают панель)
engvpnd start          # снова включить
engvpnd status         # = st
engvpnd ver
```

Удаление: `ENGVPN_RESTORE=0 engvpnd remove`.

## Аккаунт

**Настройки → Аккаунт:** ключ StealthSurf (`Authorization: Bearer stlth_…`, https://docs.stealthsurf.net/api) **или** URL подписки / `vless://` / `trojan://` / `ss://`. Хранится в `data/account.json` (0600).

## Архитектура 1.0 (Rust)

```
$PREFIX/
  sbin/engvpn-daemon   # HTTP :8790, auth, snapshot, invoke, diagnostics
  sbin/engvpnd         # CLI → daemon + share/*.sh
  share/engvpn/www/    # статическая UI
  share/engvpn/*.sh    # service, transparent, dpi, warp, update, …
  data/                # state, cores, conf
```

- Supervisor / keepalive / flock — по-прежнему `service.sh` (без шторма процессов).  
- Diagnostics читает `/proc` **в процессе Rust** (нет V8 Fatal 133).  
- Dual uptime: сессия аддона (`data/.addon-uptime-since`) + аптайм панели.  
- Feed `latest.json` — SHA-256 (+ Minisign), GitHub Releases `engvpn-1.0.0`.

### Что нового в 1.0.0

- Полная замена Node-панели на **`engvpn-daemon`** (axum, без Entware Node).  
- Архив прежнего стека: `engvpn/archive/`.  
- Установщик и README без требования `opkg install node`.  
- Кросс-сборка **aarch64-musl** (`cargo-zigbuild` + Zig; обёртка `scripts/zig-wrap.sh` снимает несовместимый `--fix-cortex-a53-843419`).  
- В `merlin-aarch64.tar.gz` **запрещён** host-бинарник: только ELF AArch64 (иначе сборка падает).  
- `ENGVPN_SKIP_CROSS=1` — только `merlin-x86_64` для smoke; release feed не трогает.

## CLI (кратко)

| Команда | Назначение |
| --- | --- |
| `serve` | Панель foreground (`engvpn-daemon serve`) |
| `start` / `stop` / `restart` / `off` | Сервис через `service.sh` |
| `status` / `st` / `ver` | Статус / версия |
| `update` / `up` / `check` | Feed |
| `transparent` / `dpi` / `warp` / `smartdns` / `privacy` | Сеть |
| `backup` / `discover` / `watchdog` / `fix` / `clean` | Обслуживание |

Порт: `ENGVPN_PORT` (по умолчанию **8790**). Лог: `/tmp/engvpn-<hash>/engvpnd.log`.

## Сборка / smoke

```sh
cd engvpn
# Zig ≥0.13 в PATH (или ~/.local/zig15) + cargo-zigbuild; запасной путь: gcc-aarch64-linux-gnu
cargo test -p engvpn-daemon
./build-package.sh          # обязателен реальный aarch64 для merlin-aarch64.tar.gz
ENGVPN_SKIP_CROSS=1 ./smoke-test.sh   # smoke: только host x86_64, без подмены aarch64
./publish-release.sh --push
```

## Отличия от официального StealthSurf

| Upstream | EngVPN 1.0 |
| --- | --- |
| Закрытый routerd / Ferrum | Open Rust panel + zapret/nfqws + Xray в слоте Ferrum |
| Только приложение | API-ключ + URL подписки на роутере |
| — | SHA-256 + Minisign |
| — | **Статический Rust-демон**, без Node |
