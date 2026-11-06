# StealthSurf UI for Asuswrt-Merlin

Аддон для роутеров на **Asuswrt-Merlin**: StealthSurf — провайдер VPN; transparent proxy, каталог конфигов и routing — на роутере через API-ключ(и) `stlth_…`.

**Актуальный релиз:** [v1.0.11](https://github.com/Homavi88/Stealthsurf-Asus/releases/latest)

## Установка на роутер

Нужны: Merlin + JFFS custom scripts + **Entware** (`amtm`).

```sh
curl -fsSL https://raw.githubusercontent.com/Homavi88/Stealthsurf-Asus/main/install.sh | sh
```

После установки: выйти из WebUI → зайти снова → **VPN → StealthSurf**  
(URL обычно `http://192.168.1.1/user1.asp`). Страница использует нативную оболочку Merlin
(меню, `FormTitle` / `FormTable`, `button_gen`) — как у XrayUI.

Короткий CLI: **`ssurf`** (полное имя `stealthsurf` тоже работает).

```sh
ssurf key 'stlth_…'
ssurf sy && ssurf ls
ssurf ap <id> && ssurf mode redirect && ssurf up
ssurf st
ssurf h          # справка
ssurf m          # меню
```

Подробнее: [docs/INSTALL.md](./docs/INSTALL.md) · [docs/CLI.md](./docs/CLI.md)

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

- Ключи только на роутере (`/opt/etc/stealthsurf.conf`)
- Sync тянет все конфиги; при смене настроек на сайте — rebuild включённых outbound
- Multi-runtime: Xray + Hysteria2 (auto-download) + WG; AmneziaWG — если установлен `awg-quick`

## Быстрый UX

1. API-ключ → **Синхронизировать**
2. Enable outbounds + **default**
3. Режим **redirect** (или **tproxy**)
4. Опционально: routing / политики MAC
5. **Старт** — LAN без системного прокси идёт через StealthSurf

## Документация

- [docs/INSTALL.md](./docs/INSTALL.md) — установка, пути, smoke
- [docs/CLI.md](./docs/CLI.md) — короткие команды `ssurf`
- [docs/PROTOCOLS.md](./docs/PROTOCOLS.md) — протоколы и sync сайт→роутер
- [docs/TPROXY_VS_REDIRECT.md](./docs/TPROXY_VS_REDIRECT.md)
- [docs/POLICIES.md](./docs/POLICIES.md) · [docs/ROUTING.md](./docs/ROUTING.md)
- [docs/BACKUP_AND_LOGS.md](./docs/BACKUP_AND_LOGS.md) — backup и логи в WebUI
- [docs/FAQ.md](./docs/FAQ.md) · [docs/VERIFICATION_CHECKLIST.md](./docs/VERIFICATION_CHECKLIST.md)
- [docs/ROUTER_MATRIX.md](./docs/ROUTER_MATRIX.md) — заполнить после теста на железе
- [ROADMAP.md](./ROADMAP.md)

## Сборка из исходников

```sh
npm run pack   # packaged/asuswrt-merlin-stealthsurf.tar.gz
```

CI публикует Release на тег `v*`.

## Провайдер

- [docs.stealthsurf.net](https://docs.stealthsurf.net)
- [API](https://docs.stealthsurf.net/api)
