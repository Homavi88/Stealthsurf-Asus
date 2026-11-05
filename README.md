# StealthSurf UI for Asuswrt-Merlin

Аддон для роутеров на **Asuswrt-Merlin**: StealthSurf — провайдер VPN, а весь интерфейс, transparent proxy, каталог конфигов и routing живут на роутере через API-ключ(и) `stlth_…`.

## Как это устроено

```text
LAN / Wi‑Fi ──► iptables REDIRECT|TPROXY ──► Xray (dokodemo-door)
                                              │
                   outbounds: ss-<id> × N  ◄───┤  routing rules
                                              │  (domain → ss-101, …)
                                              ▼
                                      StealthSurf nodes
                                              ▲
                         Bearer stlth_… ──────┘
                         api.stealthsurf.net
```

- API-ключ(и) хранятся только на роутере (`/opt/etc/stealthsurf.conf` + `api_keys.json`).
- Sync забирает **все** конфиги и custom-subscriptions аккаунта(ов).
- Несколько outbounds `ss-<id>` + правила «домен/geosite → конкретный VPN».
- Dataplane: Xray (VLESS/Trojan/SS) + опционально Hysteria2 / WireGuard / AmneziaWG.

## Требования

- Asuswrt-Merlin `384.15+` / `3006.102.1+`
- JFFS custom scripts включены
- **Entware уже установлен** через `amtm`

## Установка одной командой

```sh
curl -fsSL https://raw.githubusercontent.com/Homavi88/Stealthsurf-Asus/main/install.sh | sh
```

Установщик: проверяет Entware → `opkg` deps → пакет из **GitHub Releases** (fallback `packaged/`) → хуки → автоскачивание Xray при необходимости.

После установки: выйти из WebUI и зайти снова → **VPN → StealthSurf**.

Удаление: `stealthsurf uninstall` (чистит iptables/ip rule).

## Быстрый старт

1. API-ключ(и) → **Синхронизировать**
2. Включить нужные конфиги как outbounds, выбрать **default**
3. Режим **redirect** (или **tproxy**)
4. Опционально: routing / политики MAC
5. **Старт** — клиенты LAN без системного прокси идут через StealthSurf

## CLI (основные)

```sh
stealthsurf version
stealthsurf set-key 'stlth_…'          # или add-key для нескольких
stealthsurf sync
stealthsurf list
stealthsurf apply <config_id>          # sole outbound + start
stealthsurf enable <id> | disable <id>
stealthsurf set-default ss-205
stealthsurf preset ru-direct 205
stealthsurf set-mode redirect|tproxy|proxy
stealthsurf set-dns-mode OFF|BYPASS|REDIRECT
stealthsurf start|stop|restart|status
stealthsurf diag | test-config | connectivity
stealthsurf backup [note] | backups | restore <file>
stealthsurf logs activity|errors|devices
stealthsurf devices                    # снимок LAN IP/MAC в лог
stealthsurf check-update               # сравнить с GitHub Releases
stealthsurf update                     # поставить latest с GitHub
stealthsurf uninstall
```

В UI всегда видны **Старт / Стоп / Рестарт**, установленная версия и подсветка, если на GitHub есть новее.

Backup и логи: [docs/BACKUP_AND_LOGS.md](./docs/BACKUP_AND_LOGS.md).  
Паттерны Merlin/dataplane vs xrayui: [docs/XRAYUI_COMPARISON.md](./docs/XRAYUI_COMPARISON.md).

Полный список: `stealthsurf` без аргументов.

## Сборка из исходников

```sh
npm install   # не обязателен — сборка на чистом Node
npm run build # dist/
npm run pack  # packaged/asuswrt-merlin-stealthsurf.tar.gz
```

CI (`.github/workflows/release.yml`) собирает артефакт на PR/push и публикует Release на тег `v*`.

## Документация

- [docs/INSTALL.md](./docs/INSTALL.md)
- [docs/TPROXY_VS_REDIRECT.md](./docs/TPROXY_VS_REDIRECT.md)
- [docs/POLICIES.md](./docs/POLICIES.md)
- [docs/ROUTING.md](./docs/ROUTING.md)
- [docs/FAQ.md](./docs/FAQ.md)
- [docs/ROUTER_MATRIX.md](./docs/ROUTER_MATRIX.md)
- [ROADMAP.md](./ROADMAP.md)

## Документация провайдера

- [docs.stealthsurf.net](https://docs.stealthsurf.net)
- [API](https://docs.stealthsurf.net/api)
