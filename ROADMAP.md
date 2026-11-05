# Roadmap: до полноценной работы на роутере

Документ описывает, что ещё нужно реализовать в аддоне **StealthSurf UI for Asuswrt-Merlin**, чтобы он работал как полноценный плагин: трафик LAN шёл через VPN StealthSurf, были политики устройств и правила по адресам/доменам.

Эталон архитектуры dataplane: [asuswrt-merlin-xrayui](https://github.com/DanielLavrushin/asuswrt-merlin-xrayui) (`control.sh`, `firewall.sh`, `dnsmasq.sh`, Bypass/Redirect Policy, TPROXY).

Репозиторий: https://github.com/Homavi88/Stealthsurf-Asus

---

## Текущее состояние

Уже есть:

- клиент StealthSurf API (API-ключ, sync конфигов, смена location/protocol);
- сборка `connection_url` → outbound Xray (VLESS / Trojan / Shadowsocks);
- локальные inbound SOCKS (`10808`) и HTTP (`10809`);
- CLI start/stop/status и черновой WebUI.

Чего нет (из‑за этого аддон ещё не «полноценный» на роутере):

- перехвата LAN-трафика (transparent proxy);
- iptables / ip rule / TPROXY;
- политик Bypass/Redirect по MAC и портам;
- routing по доменам, CIDR, geoip/geosite;
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
| Правило domain/CIDR | часть трафика direct, часть proxy (или block) |
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

## Фаза 3 — Правила адресов и доменов

**Приоритет: P1**

Два слоя (как в xrayui Routing):

### 3.1 Routing внутри Xray

- [ ] Правила `domain` / `geosite` / `geoip` / `ip` / `cidr` → `proxy` | `direct` | `block`
- [ ] Загрузка/обновление `geoip.dat` / `geosite.dat`
- [ ] Пресеты под StealthSurf:
  - [ ] весь трафик через VPN
  - [ ] RU / private → direct, остальное → VPN
  - [ ] только выбранные сайты/сервисы через VPN
  - [ ] block ads / malware (опционально)

### 3.2 DNS + ipset (ускорение и разгрузка CPU)

- [ ] Перехват DNS LAN (udp/tcp 53) при необходимости
- [ ] Интеграция с dnsmasq: `ipset=` для доменов
- [ ] Режимы DNS bypass: `OFF` | `BYPASS` | `REDIRECT` (как в xrayui General Options)
- [ ] Сохранение/восстановление learned ipset

---

## Фаза 4 — Продуктовый слой StealthSurf

**Приоритет: P2**

- [ ] Авто-sync `connection_url` по cron и после `PATCH /configs/:id/settings`
- [ ] Отображение server stats / online / expires в UI
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
- [ ] Сборные подписки StealthSurf (`custom-subscriptions`) — опционально
- [ ] Watchdog / failover при падении ноды

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
            → Фаза 3 (routing + DNS/ipset)
                → Фаза 4 (StealthSurf UX / протоколы)
                    → Фаза 5 (полировка)
```

Минимальный путь к «уже пользуюсь каждый день»:

1. Фаза 0  
2. Фаза 1 (хотя бы REDIRECT)  
3. Простейший bypass «весь LAN в VPN» + исключение 1–2 MAC  

Остальное можно наращивать итерациями.

---

## Соответствие модулям xrayui

| Задача | Где смотреть в xrayui | Что сделать у нас |
| --- | --- | --- |
| Старт/стоп + firewall | `control.sh` | расширить `src/backend/control.sh` |
| Transparent rules | `firewall.sh`, `tun.sh` | новый `src/backend/firewall.sh` (+ опционально `tun.sh`) |
| DNS / ipset | `dnsmasq.sh` | новый `src/backend/dnsmasq.sh` |
| Политики клиентов | Bypass/Redirect UI + firewall client rules | UI + хранение policy JSON + iptables |
| Routing/geo | routing UI + geodata | генератор routing в Xray JSON + geodata update |
| Хуки Merlin | `install.sh`, `mount.sh`, cron | доработать `install.sh` / `hooks.sh` |
| Провайдер VPN | (подписки URL) | уже есть через StealthSurf API — сохранить как control plane |

Код xrayui **не копируем целиком**: берём паттерны Merlin/dataplane, StealthSurf-specific UX и API оставляем своими.

---

## Связанные документы

- [README.md](./README.md) — обзор, установка, CLI  
- StealthSurf API: https://docs.stealthsurf.net/api  
- XrayUI TPROXY: https://daniellavrushin.github.io/asuswrt-merlin-xrayui/en/tproxy  
- XrayUI Routing: https://daniellavrushin.github.io/asuswrt-merlin-xrayui/en/routing  
