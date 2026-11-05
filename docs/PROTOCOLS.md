# Поддержка протоколов StealthSurf API

Аддон строит outbound из полей API-конфига в таком порядке:

1. **`xray_config`** — если внутри есть **прокси-outbound** (не WARP-заглушка)
2. **`connection_url`** — share-link / INI (vless/trojan/ss/hy2/http/socks/WG) — **основной источник** для большинства конфигов
3. **`awg_config`** — для `amnezia-wg-2`, если INI нет в `connection_url`

## Важно про поле `xray_config`

У Live API `xray_config` часто приходит как **обёртка настроек** (`dns`, `routing`, флаги `use_xhttp` / `use_grpc` / `use_warp`…), а не готовый outbound узла. Вложенный JSON может содержать только Cloudflare WARP — его аддон **намеренно пропускает** и берёт узел из `connection_url`.

Итог: смена транспорта на сайте (XHTTP, gRPC, Reality, WARP) отражается в новом `connection_url` (и иногда в `xray_config`). После Sync аддон пересобирает dataplane, если включённые конфиги изменились.

## Синхронизация сайт → роутер

| Действие | Что происходит |
| --- | --- |
| UI **Синхронизировать** / `stealthsurf sync` | `GET /configs` (+ locations/subs) → сравнение fingerprint включённых конфигов → при изменениях `rebuild` + soft-restart |
| Autosync (cron `*/15`) | То же; rebuild **только** если изменились `connection_url` / `xray_config` / protocol / location / server у **включённых** id |
| UI **PATCH на StealthSurf** / `update-settings` | `PATCH /configs/{id}/settings` → sync → rebuild, если этот id включён |

Fingerprint хранится в `/opt/share/stealthsurf/data/enabled-configs.fp`.

Поля, влияющие на fingerprint: `id`, `protocol`, `location_id`, `server_id`, `connection_url`, `xray_config`, `awg_config`, `title`, `is_online`.

## PATCH `/configs/{id}/settings`

Обязательные поля API: **`location_id`**, **`protocol`**.

Опционально (как на сайте провайдера): `use_xhttp`, `use_grpc`, `use_warp`, `use_salamander`, `disable_reality`, `dns_preset`, `server_id`, …

После успешного PATCH провайдер пересобирает `connection_url` на своей стороне; аддон заново тянет каталог и применяет URL на роутере.

Пример CLI:

```sh
stealthsurf update-settings 42 '{"location_id":3,"protocol":"vless","use_xhttp":true}'
stealthsurf sync   # если меняли только на сайте
```

## Матрица

| Протокол API | Runtime | Источник | Зависимость |
| --- | --- | --- | --- |
| `vless`, `vless-2410` | Xray | URI (часто) / proxy в `xray_config` | Xray |
| `trojan`, `trojan-2901` | Xray | URI / `xray_config` | Xray |
| `shadowsocks-2022` | Xray | URI / `xray_config` | Xray |
| `openflux` | Xray | **proxy outbound в `xray_config`** (иначе URI) | Xray |
| `wg` | Xray wireguard outbound | INI в `connection_url` | Xray |
| `amnezia-wg-2` | awg-quick + freedom/`sockopt.interface` | INI / `awg_config` | AmneziaWG (`awg-quick`) |
| `hysteria2` | hysteria client → local SOCKS → Xray | `hy2://` URI | hysteria (auto-download) |
| `http`, `socks5` | Xray | URI | Xray |

Проверка на роутере: `stealthsurf protocols` или UI → бейджи runtime у конфигов (`/ext/stealthsurf/protocols.json`).

## Транспорты VLESS (URI)

Парсер понимает `type=`: `tcp`, `ws`, `grpc`, `h2`, `httpupgrade`, `xhttp`/`splithttp`, security `reality`/`tls`/`none`.

Для нестандартных схем OpenFlux опирайтесь на proxy-outbound внутри `xray_config`.

## Hysteria2

- На apply скачивается бинарь с GitHub Releases при отсутствии `/opt/sbin/hysteria`
- Поддержка `obfs=salamander` / `obfs-password`
- Локальный SOCKS `127.0.0.1:(18000+config_id)` как Xray outbound `ss-<id>`

## WireGuard vs AmneziaWG

- **wg** → native Xray `protocol: wireguard` (участвует в multi-outbound routing)
- **amnezia-wg-2** → отдельный iface `sswg<id>` через `awg-quick`; Xray ходит через `freedom` + `sockopt.interface`

## Связь с xrayui

Dataplane (REDIRECT/TPROXY, WAN RETURN, hooks) — как в xrayui. Каталог протоколов — через StealthSurf API, не через произвольные subscription URL. Подробнее: [XRAYUI_COMPARISON.md](./XRAYUI_COMPARISON.md).
