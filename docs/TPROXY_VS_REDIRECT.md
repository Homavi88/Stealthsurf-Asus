# TPROXY vs REDIRECT

| | REDIRECT | TPROXY |
| --- | --- | --- |
| Таблица | `nat PREROUTING` | `mangle PREROUTING` + `ip rule` |
| TCP | да | да |
| UDP / QUIC | нет (только TCP) | да |
| Модули ядра | почти всегда есть | нужен `xt_TPROXY` (+ желательно `xt_socket`) |
| Совместимость Merlin | шире | зависит от сборки |

## Рекомендация

1. Начните с **`redirect`** — весь TCP LAN через StealthSurf.
2. Если нужен UDP (игры, QUIC, DNS UDP) — переключите на **`tproxy`**.
3. Если модули недоступны, аддон сам откатывается на REDIRECT.

## CLI

```sh
stealthsurf set-mode redirect
stealthsurf set-mode tproxy
stealthsurf set-mode proxy   # только SOCKS :10808 / HTTP :10809, без LAN hijack
```

## Anti-loop

Firewall исключает:

- private / LAN CIDR
- IP роутера
- endpoint’ы всех активных нод StealthSurf (`endpoints.json`)
