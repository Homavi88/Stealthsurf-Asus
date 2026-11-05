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

## Протокол «в разработке» / apply не работает

Xray-протоколы (vless/trojan/ss) работают из коробки.  
Hysteria2 / WireGuard / AmneziaWG требуют соответствующие бинарники на роутере. OpenFlux — статус in development.

## Rate-limit API

StealthSurf: ~60 запросов/мин. При HTTP 429 подождите и повторите sync.

## Несколько API-ключей

`stealthsurf add-key 'stlth_…' 'work'` — sync объединяет конфиги всех ключей в один каталог.
