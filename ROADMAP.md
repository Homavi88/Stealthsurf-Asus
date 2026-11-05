# Roadmap: до полноценной работы на роутере

> **Статус: реализовано в v1.0.0.** Все фазы 0–5 отмечены выполненными.  
> Практическая проверка на железе: [docs/VERIFICATION_CHECKLIST.md](./docs/VERIFICATION_CHECKLIST.md).

Документ описывает целевую архитектуру аддона **StealthSurf UI for Asuswrt-Merlin**: трафик LAN через VPN StealthSurf, политики устройств и правила по адресам/доменам.

Эталон архитектуры dataplane: [asuswrt-merlin-xrayui](https://github.com/DanielLavrushin/asuswrt-merlin-xrayui) (`control.sh`, `firewall.sh`, `dnsmasq.sh`, Bypass/Redirect Policy, TPROXY).

Репозиторий: https://github.com/Homavi88/Stealthsurf-Asus

---

## Продуктовая идея (целевой UX)

Идея пользователя — **правильная** и должна стать ядром аддона:

1. В аддон на роутере вводятся **API-ключ(и)** StealthSurf (учётки / ключи провайдера).
2. Аддон по API забирает **все** VPN-конфигурации и связанные подписки аккаунта(ов): список, `connection_url`, протокол, локация, статус.
3. В WebUI роутера появляется **каталог всех подключений** провайдера — не один «активный» туннель, а полный набор конфигов с аккаунта.
4. Пользователь на роутере:
   - включает нужные конфиги как рабочие outbounds;
   - для **каждого** VPN-конфига (или поверх них) задаёт правила: какие **домены / geosite / IP / CIDR** идут через это подключение;
   - остальной трафик — default outbound (один из конфигов) или `direct` / `block`.

Технически это классическая схема Xray: **много outbounds** (по одному на StealthSurf config id) + **routing rules** (`domain:…` → `outboundTag = ss-<id>`).  
В v1.0.0 multi-outbound и правила «домены → конкретный VPN» реализованы (см. фазы 3.0–3.1 и `docs/ROUTING.md`).

Пример целевого сценария:

| Правило | Куда |
| --- | --- |
| `geosite:category-ads` | block |
| `domain:netflix.com`, `geosite:netflix` | конфиг «US-1» (StealthSurf id=101) |
| `domain:ru`, `geoip:ru`, private | direct |
| всё остальное | конфиг «NL-2» (StealthSurf id=205) |

---

## Текущее состояние (v1.0.0)

Реализовано:

- клиент StealthSurf API (один или несколько ключей, sync configs + custom-subscriptions, PATCH settings);
- каталог конфигов → несколько outbounds `ss-<id>` + default + routing domain/geosite/geoip/ip → outbound;
- transparent proxy: REDIRECT и TPROXY, firewall `STEALTHSURF`, anti-loop, DNS modes;
- политики Bypass/Redirect по MAC/портам;
- multi-runtime: Xray + Hysteria2 / WG / AWG (при наличии бинарей; OpenFlux — «в разработке»);
- хуки Merlin (services-start, service-event, nat-start, firewall-start, dnsmasq.postconf), flock, PID без killall;
- автоскачивание Xray, geodata, cron autosync/watchdog, diag/logs/backup/update, CI Releases;
- WebUI: ключи, каталог, routing, политики, режим/DNS, диагностика.

Проверка на конкретных моделях роутеров — по матрице в `docs/ROUTER_MATRIX.md`.

---

## Цель (Definition of Done)

Аддон считается готовым к повседневной работе, когда выполняются все пункты:

| Проверка | Ожидание |
| --- | --- |
| Установка с USB/Entware | one-liner из GitHub Release ставит аддон и Xray |
| После reboot | UI смонтирован, Xray и firewall-правила поднимаются сами |
| Клиент в LAN без прокси в ОС | внешний IP = IP ноды StealthSurf |
| Bypass по MAC | выбранное устройство идёт напрямую, остальные через VPN |
| API-ключ(и) в аддоне | Sync показывает **все** конфиги/подписки аккаунта(ов) StealthSurf |
| Правила на конфиг | Домен/geosite/IP можно привязать к **конкретному** VPN-конфигу (не только «в VPN / мимо») |
| Default + split | Есть default outbound и набор split-правил без ручного JSON |
| Stop / uninstall | iptables и ip rule очищены, интернет жив |
| Смена сервера/протокола в UI | PATCH в StealthSurf API → новый `connection_url` → apply без ручного SSH |
| Любой протокол аккаунта StealthSurf | Можно выбрать в UI и поднять на роутере (VLESS/Trojan/SS/Hysteria2/WG/AWG/OpenFlux и subconfig HTTP/SOCKS5) |

---

## Фаза 0 — Платформа Merlin и поставка

**Приоритет: P0**

- [x] Надёжный `install` / `uninstall` (Entware: `curl`, `jq`, `ca-certificates`, `flock` и т.д.)
- [x] Автоскачивание бинаря **xray** под архитектуру роутера (armv7 / aarch64 / …)
- [x] Хуки жизненного цикла:
  - [x] `services-start` — mount UI + автостарт при необходимости
  - [x] `service-event` — команды из WebUI с JSON payload
  - [x] `nat-start` / `firewall-start` — восстановление правил после reboot / переподъёма WAN
- [x] Блокировка `flock` на start/stop/restart (без гонок)
- [x] Корректный PID Xray **без** глобального `killall xray` (не трогать чужие процессы)
- [x] One-liner установка с GitHub: `curl …/install.sh | sh` (проверка Entware обязательна, зависимости через `opkg`, пакет из `packaged/` / Releases)
- [x] GitHub Release automation (CI) + тот же one-liner предпочитает Releases
- [x] Довести мост WebUI → backend (стабильная запись payload и вызов `service_event`)

---

## Фаза 1 — Transparent proxy (весь LAN через VPN)

**Приоритет: P0 (главный пробел)**

Без этой фазы аддон остаётся «прокси для приложений», а не VPN на роутере.

### 1.1 Генерация полного Xray config

- [x] Inbound `dokodemo-door` для transparent proxy (не только socks/http)
- [x] Режим **REDIRECT** (TCP, проще, шире совместимость моделей)
- [x] Режим **TPROXY** (TCP + UDP / QUIC): mangle + fwmark + policy routing
- [x] Anti-loop исключения:
  - [x] private / LAN подсети
  - [x] DNS/сервисы самого роутера
  - [x] IP/endpoint текущей ноды StealthSurf (чтобы не зациклить туннель)
- [x] Базовый routing: `geoip:private` → direct, остальное → proxy outbound

### 1.2 Firewall dataplane (аналог `firewall.sh` в xrayui)

- [x] `configure_firewall` при start
- [x] `cleanup_firewall` при stop / uninstall
- [x] Цепочки iptables/ip6tables (`STEALTHSURF` / аналог `XRAYUI`)
- [x] REDIRECT в `nat PREROUTING` на dokodemo-порт
- [x] TPROXY в `mangle` + `ip rule` + local route table
- [x] TCPMSS clamp, исключения WAN/WG/IPSec если нужно
- [x] Проверка модулей ядра (`xt_TPROXY`, `xt_socket`) и fallback на REDIRECT

### 1.3 Критерий фазы

- [x] Смартфон в Wi‑Fi **без** системного VPN/прокси видит IP StealthSurf
- [x] После `stealthsurf stop` интернет снова идёт напрямую

---

## Фаза 2 — Политики устройств (Bypass / Redirect)

**Приоритет: P1**

Как Bypass/Redirect Policy в xrayui:

- [x] Список клиентов из Merlin (`clientlist` / online devices)
- [x] Правила: `mode = bypass | redirect` + MAC + опционально TCP/UDP порты
- [x] Семантика:
  - нет пользовательских правил → весь LAN в VPN;
  - есть правила → нужен явный финальный catch-all `redirect`, иначе «дыра»
- [x] UI: таблица политик, добавить/удалить, Apply
- [x] Применение правил в iptables (до общего redirect/tproxy)

Примеры сценариев:

- весь дом через VPN, Smart TV — bypass;
- только ПК через VPN (redirect по MAC), остальное — direct;
- для одного устройства proxy только `443`, остальное bypass.

---

## Фаза 3 — Каталог конфигов StealthSurf + правила «домен → VPN»

**Приоритет: P1 (ядро продуктовой идеи)**

### 3.0 Каталог подключений с API (control plane)

- [x] Ввод и хранение **одного или нескольких** API-ключей StealthSurf на роутере
- [x] Sync по каждому ключу:
  - [x] `GET /configs` — все VPN-конфигурации
  - [x] `GET /profile/custom-subscriptions` (+ items) — сборные подписки, если есть
  - [x] кэш на роутере: id, title, protocol, location, expires, online, `connection_url`
- [x] UI «Мои подключения»: таблица всех конфигов с аккаунта(ов), фильтр, статус sync
- [x] Включение конфига в dataplane: «использовать как outbound» (можно несколько сразу)
- [x] Выбор **default** outbound (куда идёт трафик без спец. правила)
- [x] Per-config действия в UI: сменить location/protocol через API, обновить URL, вкл/выкл outbound
- [x] После sync/PATCH — пересобрать локальный Xray (или multi-runtime) config без ручного SSH

### 3.1 Routing: домены и адреса → конкретный VPN-конфиг

Два слоя (как в xrayui Routing), но цель — не только `proxy|direct|block`, а **привязка к StealthSurf config id**:

- [x] Каждый включённый StealthSurf config → отдельный outbound с стабильным tag (`ss-<config_id>`)
- [x] Правила пользователя в UI:
  - [x] matcher: `domain` / `full` / `keyword` / `regexp` / `geosite` / `geoip` / `ip` / `cidr`
  - [x] action outbound: `ss-<id>` | `direct` | `block` (и позже balancer)
  - [x] порядок правил (priority), как в Xray routing
- [x] UI: для выбранного VPN-конфига — список «его» доменов/групп; общий экран всех правил
- [x] Генерация `routing.rules` в Xray JSON из этих правил + anti-loop для всех endpoint’ов активных нод
- [x] Загрузка/обновление `geoip.dat` / `geosite.dat`
- [x] Пресеты:
  - [x] весь трафик через один выбранный конфиг
  - [x] RU / private → direct, остальное → default VPN
  - [x] стриминг (geosite) → конфиг страны A; остальное → конфиг B
  - [x] block ads / malware (опционально)
- [x] Валидация: нельзя сослаться на выключенный/удалённый config id

### 3.2 DNS + ipset (ускорение и разгрузка CPU)

- [x] Перехват DNS LAN (udp/tcp 53) при необходимости
- [x] Интеграция с dnsmasq: `ipset=` для доменов (в т.ч. per-outbound наборы, где возможно)
- [x] Режимы DNS bypass: `OFF` | `BYPASS` | `REDIRECT` (как в xrayui General Options)
- [x] Сохранение/восстановление learned ipset

### 3.3 Критерий фазы

- [x] После ввода API-ключа в UI видны все конфиги аккаунта без ручного импорта ссылок
- [x] Можно одновременно держать ≥2 StealthSurf outbounds
- [x] Правило «`domain:example.com` → конфиг #101» реально уводит только этот трафик в #101
- [x] Остальной трафик идёт в default outbound или direct по настройке

---

## Фаза 4 — Продуктовый слой StealthSurf

**Приоритет: P2**

- [x] Авто-sync всех ключей/конфигов по cron и после `PATCH /configs/:id/settings`
- [x] Отображение server stats / online / expires в UI (по каждому конфигу)
- [x] Обработка rate-limit и ошибок API с понятными сообщениями
- [x] **Полная поддержка всех протоколов StealthSurf** (как у провайдера в API / docs; UI и dataplane должны уметь выбрать, применить и поднять каждый):
  - [x] `vless`
  - [x] `vless-2410`
  - [x] `trojan`
  - [x] `trojan-2901`
  - [x] `shadowsocks-2022`
  - [x] `hysteria2` (клиент Hysteria2 на роутере, не только Xray)
  - [x] `wg` (WireGuard)
  - [x] `amnezia-wg-2` (AmneziaWG)
  - [x] `openflux` (если доступен в аккаунте / API)
  - [x] HTTP / SOCKS5 subconfig (доп. прокси конфигурации, где отдаёт StealthSurf)
  - [x] Единый Apply: `xray_config` (приоритет) / `connection_url` / `awg_config` → runtime (Xray / hysteria / awg) + firewall
  - [x] OpenFlux и расширенные транспорты через API `xray_config`; WG → Xray wireguard outbound; Hy2 salamander + auto-download
  - [x] В UI: матрица `protocols.json`, бейджи runtime; недоступные (нет awg) — disabled с причиной
  - [x] Multi-protocol: разные конфиги в каталоге могут работать на разных runtime одновременно (где это позволяет роутер)
- [x] Сборные подписки StealthSurf (`custom-subscriptions`) в каталоге наравне с `/configs`
- [x] Watchdog / failover: если outbound `ss-<id>` упал — fallback на другой конфиг / direct

---

---

## Фаза 5 — Полировка и эксплуатация

**Приоритет: P3**

- [x] Диагностика: dump iptables, env, тест конфига, connectivity check
- [x] Логи access/error в UI
- [x] Backup / restore настроек аддона
- [x] `stealthsurf update` с GitHub Releases
- [x] Матрица проверенных моделей роутеров
- [x] Документация: install, TPROXY vs REDIRECT, политики, FAQ

---

## Рекомендуемый порядок реализации

```text
Фаза 0 (платформа)
    → Фаза 1 (REDIRECT, затем TPROXY)
        → Фаза 2 (политики MAC)
            → Фаза 3.0–3.1 (каталог API-конфигов + домен → ss-<id>)
                → Фаза 3.2 (DNS/ipset)
                    → Фаза 4 (все протоколы / multi-runtime)
                        → Фаза 5 (полировка)
```

Минимальный путь к «уже пользуюсь каждый день»:

1. Фаза 0  
2. Фаза 1 (хотя бы REDIRECT) + один StealthSurf config как default  
3. Фаза 3.0–3.1: каталог с API + хотя бы split «домены → конфиг A / остальное → конфиг B»  
4. Политики MAC (фаза 2) по необходимости  

Остальное можно наращивать итерациями.

---

## Соответствие модулям xrayui

| Задача | Где смотреть в xrayui | Что сделать у нас |
| --- | --- | --- |
| Старт/стоп + firewall | `control.sh` | расширить `src/backend/control.sh` |
| Transparent rules | `firewall.sh`, `tun.sh` | новый `src/backend/firewall.sh` (+ опционально `tun.sh`) |
| DNS / ipset | `dnsmasq.sh` | новый `src/backend/dnsmasq.sh` |
| Политики клиентов | Bypass/Redirect UI + firewall client rules | UI + хранение policy JSON + iptables |
| Routing/geo | routing UI + geodata | генератор routing: matcher → `ss-<config_id>` / direct / block |
| Несколько outbound | outbounds + tags | каждый StealthSurf config = outbound tag |
| Хуки Merlin | `install.sh`, `mount.sh`, cron | доработать `install.sh` / `hooks.sh` |
| Провайдер VPN | (подписки URL) | StealthSurf API keys → полный каталог configs/subscriptions |

Код xrayui **не копируем целиком**: берём паттерны Merlin/dataplane, StealthSurf-specific UX и API оставляем своими.

---

## Связанные документы

- [README.md](./README.md) — обзор, установка, CLI  
- StealthSurf API: https://docs.stealthsurf.net/api  
- XrayUI TPROXY: https://daniellavrushin.github.io/asuswrt-merlin-xrayui/en/tproxy  
- XrayUI Routing: https://daniellavrushin.github.io/asuswrt-merlin-xrayui/en/routing  
