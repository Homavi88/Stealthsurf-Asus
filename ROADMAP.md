# Roadmap: до полноценной работы на роутере

Документ описывает, что ещё нужно реализовать в аддоне **StealthSurf UI for Asuswrt-Merlin**, чтобы он работал как полноценный плагин: трафик LAN шёл через VPN StealthSurf, были политики устройств и правила по адресам/доменам.

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

Технически это классическая схема Xray: **много outbounds** (по одному на StealthSurf config id) + **routing rules** (`domain:…` → `outboundTag = ss-config-101`).  
Сейчас в коде есть только sync списка и apply **одного** конфига — multi-outbound и «домены → конкретный VPN» ещё **не реализованы** (см. фазу 3.0 и DoD ниже).

Пример целевого сценария:

| Правило | Куда |
| --- | --- |
| `geosite:category-ads` | block |
| `domain:netflix.com`, `geosite:netflix` | конфиг «US-1» (StealthSurf id=101) |
| `domain:ru`, `geoip:ru`, private | direct |
| всё остальное | конфиг «NL-2» (StealthSurf id=205) |

---

## Текущее состояние

Уже есть:

- клиент StealthSurf API (один API-ключ, sync конфигов, смена location/protocol);
- сборка `connection_url` → outbound Xray (VLESS / Trojan / Shadowsocks);
- локальные inbound SOCKS (`10808`) и HTTP (`10809`);
- CLI start/stop/status и черновой WebUI.

Чего нет (из‑за этого аддон ещё не «полноценный» на роутере):

- перехвата LAN-трафика (transparent proxy);
- iptables / ip rule / TPROXY;
- политик Bypass/Redirect по MAC и портам;
- **каталога всех конфигов/подписок как одновременно доступных outbounds**;
- **правил «домен / список → конкретный VPN-конфиг StealthSurf»** (сейчас routing в roadmap описан лишь как proxy|direct|block на один туннель);
- нескольких API-ключей / учёток и единый каталог с них;
- routing по доменам, CIDR, geoip/geosite (в полном виде);
- DNS hijack + dnsmasq/ipset;
- восстановления правил после reboot / WAN up;
- надёжной поставки Xray-бинаря и Release-установки;
- поддержки **всех** протоколов StealthSurf (сейчас MVP: VLESS / Trojan / Shadowsocks через Xray; нет Hysteria2, WireGuard, AmneziaWG, OpenFlux и полного покрытия вариантов API).

Сейчас устройства ходят через VPN **только если** сами настроены на SOCKS/HTTP прокси роутера. Без transparent proxy весь Wi‑Fi/LAN через StealthSurf не пойдёт.

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

- [ ] Надёжный `install` / `uninstall` (Entware: `curl`, `jq`, `ca-certificates`, `flock` и т.д.)
- [ ] Автоскачивание бинаря **xray** под архитектуру роутера (armv7 / aarch64 / …)
- [ ] Хуки жизненного цикла:
  - [ ] `services-start` — mount UI + автостарт при необходимости
  - [ ] `service-event` — команды из WebUI с JSON payload
  - [ ] `nat-start` / `firewall-start` — восстановление правил после reboot / переподъёма WAN
- [ ] Блокировка `flock` на start/stop/restart (без гонок)
- [ ] Корректный PID Xray **без** глобального `killall xray` (не трогать чужие процессы)
- [ ] GitHub Release + `asuswrt-merlin-stealthsurf.tar.gz` + install one-liner в README
- [ ] Довести мост WebUI → backend (стабильная запись payload и вызов `service_event`)

---

## Фаза 1 — Transparent proxy (весь LAN через VPN)

**Приоритет: P0 (главный пробел)**

Без этой фазы аддон остаётся «прокси для приложений», а не VPN на роутере.

### 1.1 Генерация полного Xray config

- [ ] Inbound `dokodemo-door` для transparent proxy (не только socks/http)
- [ ] Режим **REDIRECT** (TCP, проще, шире совместимость моделей)
- [ ] Режим **TPROXY** (TCP + UDP / QUIC): mangle + fwmark + policy routing
- [ ] Anti-loop исключения:
  - [ ] private / LAN подсети
  - [ ] DNS/сервисы самого роутера
  - [ ] IP/endpoint текущей ноды StealthSurf (чтобы не зациклить туннель)
- [ ] Базовый routing: `geoip:private` → direct, остальное → proxy outbound

### 1.2 Firewall dataplane (аналог `firewall.sh` в xrayui)

- [ ] `configure_firewall` при start
- [ ] `cleanup_firewall` при stop / uninstall
- [ ] Цепочки iptables/ip6tables (`STEALTHSURF` / аналог `XRAYUI`)
- [ ] REDIRECT в `nat PREROUTING` на dokodemo-порт
- [ ] TPROXY в `mangle` + `ip rule` + local route table
- [ ] TCPMSS clamp, исключения WAN/WG/IPSec если нужно
- [ ] Проверка модулей ядра (`xt_TPROXY`, `xt_socket`) и fallback на REDIRECT

### 1.3 Критерий фазы

- [ ] Смартфон в Wi‑Fi **без** системного VPN/прокси видит IP StealthSurf
- [ ] После `stealthsurf stop` интернет снова идёт напрямую

---

## Фаза 2 — Политики устройств (Bypass / Redirect)

**Приоритет: P1**

Как Bypass/Redirect Policy в xrayui:

- [ ] Список клиентов из Merlin (`clientlist` / online devices)
- [ ] Правила: `mode = bypass | redirect` + MAC + опционально TCP/UDP порты
- [ ] Семантика:
  - нет пользовательских правил → весь LAN в VPN;
  - есть правила → нужен явный финальный catch-all `redirect`, иначе «дыра»
- [ ] UI: таблица политик, добавить/удалить, Apply
- [ ] Применение правил в iptables (до общего redirect/tproxy)

Примеры сценариев:

- весь дом через VPN, Smart TV — bypass;
- только ПК через VPN (redirect по MAC), остальное — direct;
- для одного устройства proxy только `443`, остальное bypass.

---

## Фаза 3 — Каталог конфигов StealthSurf + правила «домен → VPN»

**Приоритет: P1 (ядро продуктовой идеи)**

### 3.0 Каталог подключений с API (control plane)

- [ ] Ввод и хранение **одного или нескольких** API-ключей StealthSurf на роутере
- [ ] Sync по каждому ключу:
  - [ ] `GET /configs` — все VPN-конфигурации
  - [ ] `GET /profile/custom-subscriptions` (+ items) — сборные подписки, если есть
  - [ ] кэш на роутере: id, title, protocol, location, expires, online, `connection_url`
- [ ] UI «Мои подключения»: таблица всех конфигов с аккаунта(ов), фильтр, статус sync
- [ ] Включение конфига в dataplane: «использовать как outbound» (можно несколько сразу)
- [ ] Выбор **default** outbound (куда идёт трафик без спец. правила)
- [ ] Per-config действия в UI: сменить location/protocol через API, обновить URL, вкл/выкл outbound
- [ ] После sync/PATCH — пересобрать локальный Xray (или multi-runtime) config без ручного SSH

### 3.1 Routing: домены и адреса → конкретный VPN-конфиг

Два слоя (как в xrayui Routing), но цель — не только `proxy|direct|block`, а **привязка к StealthSurf config id**:

- [ ] Каждый включённый StealthSurf config → отдельный outbound с стабильным tag (`ss-<config_id>`)
- [ ] Правила пользователя в UI:
  - [ ] matcher: `domain` / `full` / `keyword` / `regexp` / `geosite` / `geoip` / `ip` / `cidr`
  - [ ] action outbound: `ss-<id>` | `direct` | `block` (и позже balancer)
  - [ ] порядок правил (priority), как в Xray routing
- [ ] UI: для выбранного VPN-конфига — список «его» доменов/групп; общий экран всех правил
- [ ] Генерация `routing.rules` в Xray JSON из этих правил + anti-loop для всех endpoint’ов активных нод
- [ ] Загрузка/обновление `geoip.dat` / `geosite.dat`
- [ ] Пресеты:
  - [ ] весь трафик через один выбранный конфиг
  - [ ] RU / private → direct, остальное → default VPN
  - [ ] стриминг (geosite) → конфиг страны A; остальное → конфиг B
  - [ ] block ads / malware (опционально)
- [ ] Валидация: нельзя сослаться на выключенный/удалённый config id

### 3.2 DNS + ipset (ускорение и разгрузка CPU)

- [ ] Перехват DNS LAN (udp/tcp 53) при необходимости
- [ ] Интеграция с dnsmasq: `ipset=` для доменов (в т.ч. per-outbound наборы, где возможно)
- [ ] Режимы DNS bypass: `OFF` | `BYPASS` | `REDIRECT` (как в xrayui General Options)
- [ ] Сохранение/восстановление learned ipset

### 3.3 Критерий фазы

- [ ] После ввода API-ключа в UI видны все конфиги аккаунта без ручного импорта ссылок
- [ ] Можно одновременно держать ≥2 StealthSurf outbounds
- [ ] Правило «`domain:example.com` → конфиг #101» реально уводит только этот трафик в #101
- [ ] Остальной трафик идёт в default outbound или direct по настройке

---

## Фаза 4 — Продуктовый слой StealthSurf

**Приоритет: P2**

- [ ] Авто-sync всех ключей/конфигов по cron и после `PATCH /configs/:id/settings`
- [ ] Отображение server stats / online / expires в UI (по каждому конфигу)
- [ ] Обработка rate-limit и ошибок API с понятными сообщениями
- [ ] **Полная поддержка всех протоколов StealthSurf** (как у провайдера в API / docs; UI и dataplane должны уметь выбрать, применить и поднять каждый):
  - [ ] `vless`
  - [ ] `vless-2410`
  - [ ] `trojan`
  - [ ] `trojan-2901`
  - [ ] `shadowsocks-2022`
  - [ ] `hysteria2` (клиент Hysteria2 на роутере, не только Xray)
  - [ ] `wg` (WireGuard)
  - [ ] `amnezia-wg-2` (AmneziaWG)
  - [ ] `openflux` (если доступен в аккаунте / API)
  - [ ] HTTP / SOCKS5 subconfig (доп. прокси конфигурации, где отдаёт StealthSurf)
  - [ ] Единый Apply: парсинг `connection_url` / конфига протокола → нужный runtime (Xray / hysteria / awg / wg) + firewall
  - [ ] В UI: только реально поддерживаемые на роутере протоколы активны; остальные — понятный статус «в разработке», без «тихого» apply
  - [ ] Multi-protocol: разные конфиги в каталоге могут работать на разных runtime одновременно (где это позволяет роутер)
- [ ] Сборные подписки StealthSurf (`custom-subscriptions`) в каталоге наравне с `/configs`
- [ ] Watchdog / failover: если outbound `ss-<id>` упал — fallback на другой конфиг / direct

---

---

## Фаза 5 — Полировка и эксплуатация

**Приоритет: P3**

- [ ] Диагностика: dump iptables, env, тест конфига, connectivity check
- [ ] Логи access/error в UI
- [ ] Backup / restore настроек аддона
- [ ] `stealthsurf update` с GitHub Releases
- [ ] Матрица проверенных моделей роутеров
- [ ] Документация: install, TPROXY vs REDIRECT, политики, FAQ

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
