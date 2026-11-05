# FAQ

## Устройства в Wi‑Fi не идут через VPN

1. Режим должен быть `redirect` или `tproxy`, не `proxy`
2. `stealthsurf status` → `running: true`
3. `stealthsurf diag` — проверьте цепочку `STEALTHSURF` в iptables
4. На клиенте не должно быть своего системного VPN/прокси

## После reboot правил нет

Проверьте хуки:

- `/jffs/scripts/services-start` — `mount_ui` + `autostart`
- `/jffs/scripts/nat-start` и `firewall-start` — `firewall-restore`

JFFS custom scripts должны быть включены.

## Stop / uninstall ломает интернет?

`stealthsurf stop` и `uninstall` чистят цепочки `STEALTHSURF` и `ip rule`. Если интернет пропал — перезапустите firewall роутера (`service restart_firewall`) или reboot.

## Протокол «недоступен» / apply не работает

- **vless / trojan / ss / openflux / http / socks5 / wg** — через Xray (`xray_config` предпочтительнее URI; OpenFlux почти всегда из `xray_config`)
- **hysteria2** — клиент скачивается при apply (или положите `/opt/sbin/hysteria`)
- **amnezia-wg-2** — нужен `awg-quick` / AmneziaWG на роутере

Матрица: `stealthsurf protocols` или бейджи в UI. Подробнее: [PROTOCOLS.md](./PROTOCOLS.md).

## Rate-limit API

StealthSurf: ~60 запросов/мин. При HTTP 429 подождите и повторите sync.

## Несколько API-ключей

`stealthsurf add-key 'stlth_…' 'work'` — sync объединяет конфиги всех ключей в один каталог.
