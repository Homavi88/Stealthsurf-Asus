# Политики устройств (Bypass / Redirect)

Семантика как в xrayui Bypass/Redirect Policy.

## Правила

Каждое правило: `mode` + `mac` + опционально `ports` / `proto`.

- **bypass** — устройство (или порты) идёт напрямую, минуя VPN
- **redirect** — устройство (или порты) принудительно в transparent proxy

## Catch-all

- Нет пользовательских правил → весь LAN в VPN (если mode ≠ proxy)
- Есть правила без catch-all → unmatched LAN остаётся **direct** (возможна «дыра»)
- Включите **Catch-all redirect** в UI (поле `catchall: true` в `policies.json`)

## Примеры

Весь дом через VPN, Smart TV напрямую:

```json
{
  "catchall": true,
  "rules": [
    { "mode": "bypass", "mac": "AA:BB:CC:DD:EE:FF", "name": "TV" }
  ]
}
```

Только ПК через VPN:

```json
{
  "catchall": false,
  "rules": [
    { "mode": "redirect", "mac": "11:22:33:44:55:66", "name": "PC" }
  ]
}
```

Только HTTPS для одного устройства:

```json
{
  "catchall": true,
  "rules": [
    { "mode": "redirect", "mac": "11:22:33:44:55:66", "ports": "443", "proto": "tcp" },
    { "mode": "bypass", "mac": "11:22:33:44:55:66" }
  ]
}
```

Порядок в цепочке: сначала конкретные MAC-правила, затем catch-all.
