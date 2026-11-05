# Поддержка протоколов StealthSurf API

Аддон строит outbound из полей API-конфига в таком порядке:

1. **`xray_config`** — готовый Xray JSON (предпочтительно; покрывает OpenFlux, xhttp/grpc и расширенные транспорты)
2. **`connection_url`** — share-link / INI (vless/trojan/ss/hy2/http/socks/WG)
3. **`awg_config`** — для `amnezia-wg-2`, если INI нет в `connection_url`

## Матрица

| Протокол API | Runtime | Источник | Зависимость |
| --- | --- | --- | --- |
| `vless`, `vless-2410` | Xray | `xray_config` или URI | Xray |
| `trojan`, `trojan-2901` | Xray | `xray_config` или URI | Xray |
| `shadowsocks-2022` | Xray | URI / `xray_config` | Xray |
| `openflux` | Xray | **`xray_config`** (обязателен для полной поддержки) | Xray |
| `wg` | Xray wireguard outbound | INI в `connection_url` | Xray |
| `amnezia-wg-2` | awg-quick + freedom/`sockopt.interface` | INI / `awg_config` | AmneziaWG (`awg-quick`) |
| `hysteria2` | hysteria client → local SOCKS → Xray | `hy2://` URI | hysteria (auto-download) |
| `http`, `socks5` | Xray | URI | Xray |

Проверка на роутере: `stealthsurf protocols` или UI → бейджи runtime у конфигов (`/ext/stealthsurf/protocols.json`).

## Транспорты VLESS (URI)

Парсер понимает `type=`: `tcp`, `ws`, `grpc`, `h2`, `httpupgrade`, `xhttp`/`splithttp`, security `reality`/`tls`/`none`.

Для нестандартных схем OpenFlux всегда опирайтесь на `xray_config` из API.

## Hysteria2

- На apply скачивается бинарь с GitHub Releases при отсутствии `/opt/sbin/hysteria`
- Поддержка `obfs=salamander` / `obfs-password`
- Локальный SOCKS `127.0.0.1:(18000+config_id)` как Xray outbound `ss-<id>`

## WireGuard vs AmneziaWG

- **wg** → native Xray `protocol: wireguard` (участвует в multi-outbound routing)
- **amnezia-wg-2** → отдельный iface `sswg<id>` через `awg-quick`; Xray ходит через `freedom` + `sockopt.interface`

## Связь с xrayui

Dataplane (REDIRECT/TPROXY, WAN RETURN, hooks) — как в xrayui. Каталог протоколов — через StealthSurf API, не через произвольные subscription URL. Подробнее: [XRAYUI_COMPARISON.md](./XRAYUI_COMPARISON.md).
