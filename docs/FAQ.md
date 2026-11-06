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

## Пропала вкладка VPN → StealthSurf и/или команда `ssurf`

Частые причины:

1. **Неудачное обновление** (старые версии удаляли файлы до проверки архива) — с v1.0.12 update атомарный.
2. **Entware на USB** временно не смонтирован → `/opt/bin/ssurf` «не найден», хотя скрипт на JFFS жив.
3. Случайный `ssurf rm` / `uninstall` в старых версиях (алиас `rm` убран; нужен `ssurf un --yes`).

Восстановление:

```sh
/jffs/scripts/stealthsurf doctor
# если скрипта тоже нет — переустановите one-liner из README
```

Затем выйти из WebUI и зайти снова.

## Протокол «недоступен» / apply не работает

- **vless / trojan / ss / openflux / http / socks5 / wg** — через Xray (часто из `connection_url`; OpenFlux — proxy outbound в `xray_config`)
- **hysteria2** — клиент скачивается при apply (или положите `/opt/sbin/hysteria`)
- **amnezia-wg-2** — нужен `awg-quick` / AmneziaWG на роутере

Матрица: `stealthsurf protocols` или бейджи в UI. Подробнее: [PROTOCOLS.md](./PROTOCOLS.md).

## Изменил настройки на сайте StealthSurf — на роутере старый протокол

1. Нажмите **Синхронизировать** в UI или `stealthsurf sync`
2. Аддон сравнит fingerprint включённых конфигов (`connection_url`, protocol, location, `xray_config`…)
3. При изменениях автоматически сделает rebuild + soft-restart Xray
4. Autosync каждые **15 минут** делает то же самое

Если VPN ещё не запускали — sync только обновит кэш; затем `apply` / `start`.

## Rate-limit API

StealthSurf: ~60 запросов/мин. При HTTP 429 подождите и повторите sync.

## Несколько API-ключей

`stealthsurf add-key 'stlth_…' 'work'` — sync объединяет конфиги всех ключей в один каталог.
