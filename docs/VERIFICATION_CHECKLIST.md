# Чеклист проверки реализации (после установки на роутер)

Выполнять по порядку. Отмечайте результат.

## 0. Платформа и поставка

- [ ] `curl -fsSL …/install.sh | sh` завершается без ошибки (Entware обязателен)
- [ ] В WebUI есть вкладка **VPN → StealthSurf** после re-login
- [ ] `stealthsurf version` → `1.0.0`
- [ ] `which xray` или `/opt/sbin/xray` существует (`stealthsurf install-xray` при необходимости)
- [ ] После reboot: UI снова смонтирован, при наличии конфига — автостарт
- [ ] Параллельный `start`/`stop` не гоняет гонки (`flock`)
- [ ] `stealthsurf stop` **не** убивает чужой `xray` (нет `killall xray`)
- [ ] GitHub Release / `stealthsurf update` качает пакет с Releases

## 1. Transparent proxy

- [ ] `stealthsurf set-mode redirect` + `start`
- [ ] Смартфон в Wi‑Fi **без** системного VPN/прокси: внешний IP = IP ноды StealthSurf
- [ ] `stealthsurf set-mode tproxy` (если есть `xt_TPROXY`) — UDP тоже через туннель
- [ ] Anti-loop: роутер/LAN/endpoint ноды не зациклены (`stealthsurf diag` → endpoints + iptables)
- [ ] `stealthsurf stop` → интернет снова напрямую, цепочка `STEALTHSURF` пуста/удалена

## 2. Политики MAC

- [ ] `stealthsurf clients` показывает устройства
- [ ] Bypass по MAC: выбранное устройство идёт direct, остальные через VPN
- [ ] Redirect-only по MAC без catch-all: unmatched = direct
- [ ] Catch-all включён → остальной LAN в VPN
- [ ] Правило с портом `443` применяется только к этому порту

## 3. Каталог + routing

- [ ] Один/несколько API-ключей → sync показывает **все** конфиги аккаунта(ов)
- [ ] Custom-subscriptions видны в UI / `subscriptions.json`
- [ ] Включены ≥2 outbounds (`enable`), выбран default
- [ ] Правило `domain:example.com → ss-101` уводит только этот трафик в #101
- [ ] Остальное → default outbound / direct по настройке
- [ ] Пресеты: `all-vpn`, `ru-direct`, `streaming-split`, `block-ads`
- [ ] Ссылка на выключенный `ss-<id>` отклоняется валидацией
- [ ] `stealthsurf geodata` обновляет geoip/geosite
- [ ] DNS mode OFF / BYPASS / REDIRECT переключается без поломки резолва

## 4. Протоколы и продукт

- [ ] VLESS / Trojan / Shadowsocks-2022: Apply + start OK
- [ ] PATCH location/protocol в UI → новый URL / xray_config → rebuild без SSH
- [ ] `stealthsurf protocols` — openflux/wg/hy2/awg статусы соответствуют железу
- [ ] Apply openflux с `xray_config` → outbound без ручного URI
- [ ] Apply wg INI → Xray wireguard outbound в multi-outbound
- [ ] Apply hysteria2 → локальный SOCKS bridge + tag `ss-<id>`
- [ ] Hysteria2 / WG / AWG: если бинарь есть — поднимаются; если нет — понятный статус «нужен бинарь / в разработке»
- [ ] OpenFlux: при наличии proxy в `xray_config` — apply OK; без него — понятная ошибка (не silent)
- [ ] Autosync (cron) обновляет кэш; watchdog поднимает упавший Xray
- [ ] Rate-limit 429 даёт понятное сообщение

## 5. Полировка / backup / логи

- [ ] `stealthsurf diag` — dump iptables, env, protocols, state
- [ ] `stealthsurf backup` создаёт архив; в `policies.json` внутри есть `ip=` устройств
- [ ] `stealthsurf backups` / restore из UI и CLI
- [ ] `stealthsurf logs activity` показывает действия (start/apply/firewall)
- [ ] `stealthsurf devices` пишет IP/MAC клиентов в `devices.log` и `activity.log`
- [ ] Ошибки попадают в `logs/errors.log`
- [ ] Документация: `docs/BACKUP_AND_LOGS.md`

## Быстрый smoke (минимум «уже пользуюсь»)

```sh
stealthsurf set-key 'stlth_…'
stealthsurf sync
stealthsurf apply <id>
stealthsurf set-mode redirect
stealthsurf start
# телефон в Wi‑Fi → проверить IP
stealthsurf stop
```
