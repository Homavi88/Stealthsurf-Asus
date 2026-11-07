<p align="center">
  <img src="./docs/screenshots/01-status-running.png" alt="StealthSurf on Asuswrt-Merlin" width="920">
</p>

<h1 align="center">StealthSurf</h1>

<p align="center">
  <strong>VPN провайдера — на весь дом через роутер Asuswrt-Merlin</strong><br>
  WebUI как у нативных аддонов Merlin · sync с API · transparent proxy · routing · CLI <code>ssurf</code>
</p>

<p align="center">
  <a href="https://github.com/Homavi88/Stealthsurf-Asus/releases/latest"><img alt="Release" src="https://img.shields.io/github/v/release/Homavi88/Stealthsurf-Asus?style=flat-square&label=release&color=2f6fed"></a>
  <a href="https://github.com/Homavi88/Stealthsurf-Asus/releases/latest"><img alt="Downloads" src="https://img.shields.io/github/downloads/Homavi88/Stealthsurf-Asus/total?style=flat-square&color=2d8a5f"></a>
  <a href="./docs/INSTALL.md"><img alt="Merlin" src="https://img.shields.io/badge/Asuswrt--Merlin-addon-1f2a2e?style=flat-square"></a>
  <a href="https://docs.stealthsurf.net"><img alt="StealthSurf" src="https://img.shields.io/badge/provider-StealthSurf-0b3d2e?style=flat-square"></a>
</p>

<p align="center">
  <a href="#установка"><strong>Установка</strong></a> ·
  <a href="#возможности"><strong>Возможности</strong></a> ·
  <a href="#веб-интерфейс"><strong>WebUI</strong></a> ·
  <a href="#cli-за-минуту"><strong>CLI</strong></a> ·
  <a href="#документация"><strong>Документация</strong></a>
</p>

---

Один API-ключ `stlth_…` — и весь LAN/Wi‑Fi идёт через узлы StealthSurf: без клиента на телефонах, с правилами «YouTube → VPN, RU → direct», политиками по MAC и бэкапами. Интерфейс живёт во вкладке **VPN → StealthSurf** и выглядит как родной Merlin (тот же каркас, что у XrayUI).

## Установка

Нужны Merlin, JFFS custom scripts и Entware (`amtm`). Одна команда на роутере:

```sh
curl -fsSL https://raw.githubusercontent.com/Homavi88/Stealthsurf-Asus/main/install.sh | sh
```

Затем: logout → login в WebUI → **VPN → StealthSurf**  
Актуальный пакет: [**Releases → latest**](https://github.com/Homavi88/Stealthsurf-Asus/releases/latest) (`asuswrt-merlin-stealthsurf.tar.gz`).

## Возможности

| | |
| --- | --- |
| **Каталог из API** | Sync конфигов StealthSurf, несколько ключей, enable / default outbound |
| **Transparent proxy** | `redirect` / `tproxy` на весь LAN или только SOCKS/HTTP (`proxy`) |
| **Routing** | domain / geosite / geoip → `ss-<id>`, пресеты, автоподсказки |
| **Политики MAC** | bypass / redirect по устройствам |
| **Надёжность** | автостарт, watchdog, плановый reboot, backup, auto geoip/geosite |
| **Безопасный dataplane** | отдельный mark/table от XrayUI; старт блокируется при конфликте |
| **CLI** | короткий `ssurf` + меню `ssurf m` |

Мультипротоколы: VLESS / Trojan / SS2022 / Hysteria2 / WireGuard (+ AmneziaWG при наличии `awg`).

## Веб-интерфейс

Нативная оболочка Merlin: FormTable-секции, кнопки справа, **Apply**, footer версии, модалка настроек.

<p align="center">
  <img src="./docs/screenshots/06-routing-builder.png" alt="Routing rule builder" width="900">
</p>

| Каталог | Подсказки доменов |
| --- | --- |
| ![Каталог](./docs/screenshots/02-catalog.png) | ![Suggest](./docs/screenshots/07-routing-suggest.png) |

| Mode / DNS | Настройки |
| --- | --- |
| ![Mode](./docs/screenshots/04-mode-dns.png) | ![Settings](./docs/screenshots/08-settings-modal.png) |

Конфликт с работающим XrayUI — старт заблокирован (оба transparent proxy ломают LAN):

<p align="center">
  <img src="./docs/screenshots/05-xrayui-conflict.png" alt="XrayUI conflict guard" width="720">
</p>

## Старт за 5 шагов

1. Вставить API-ключ → **sync**
2. Включить outbounds и выбрать **default**
3. Режим **redirect** (или **tproxy**)
4. По желанию: routing / MAC-политики / настройки
5. **start** — устройства в Wi‑Fi идут через StealthSurf без системного VPN

## CLI за минуту

```sh
ssurf key 'stlth_…'
ssurf sy && ssurf ls
ssurf ap <id>
ssurf mode redirect
ssurf up && ssurf st
```

| | |
| --- | --- |
| `ssurf up` / `dn` / `re` | старт / стоп / рестарт |
| `ssurf sy` · `ls` · `ap <id>` | sync · список · apply |
| `ssurf mode` · `dns` · `rb` | dataplane · DNS · rebuild |
| `ssurf bak` · `cu` · `upd` | backup · check-update · update |
| `ssurf lv` · `iv v1.0.16` | list versions · install / rollback |
| `ssurf doctor` · `un --yes` | восстановление · удаление |
| `ssurf h` · `ssurf m` | справка · меню |

Если пропал интернет после transparent: `ssurf mode proxy && ssurf dn` или `ssurf doctor`.

Полная шпаргалка: [docs/CLI.md](./docs/CLI.md).

## Как устроено

```text
LAN / Wi‑Fi ──► iptables REDIRECT | TPROXY ──► Xray
                                               │
                    outbounds ss-<id> × N  ◄────┤  routing
                                               ▼
                                       StealthSurf nodes
                                               ▲
                          Bearer stlth_… ──────┘
                          api.stealthsurf.net
```

Ключи только на роутере (`/opt/etc/stealthsurf.conf`). Sync тянет каталог; смена настроек на сайте → rebuild включённых outbound.

## Документация

| | |
| --- | --- |
| [INSTALL](./docs/INSTALL.md) | установка и smoke |
| [CLI](./docs/CLI.md) | команды `ssurf` |
| [ROUTING](./docs/ROUTING.md) · [POLICIES](./docs/POLICIES.md) | правила и MAC |
| [PROTOCOLS](./docs/PROTOCOLS.md) | протоколы и sync |
| [FAQ](./docs/FAQ.md) · [BACKUP](./docs/BACKUP_AND_LOGS.md) | типовые проблемы |
| [DEFERRED_APPLY](./docs/DEFERRED_APPLY.md) | правило «Применить» для настроек |
| [ROADMAP](./ROADMAP.md) | план |

Провайдер: [docs.stealthsurf.net](https://docs.stealthsurf.net) · [API](https://docs.stealthsurf.net/api)

## Сборка

```sh
npm run pack   # → packaged/asuswrt-merlin-stealthsurf.tar.gz
```

CI публикует GitHub Release на тег `v*`.
