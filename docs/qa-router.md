# QA на роутере (SurfGate VPN polish)

В CI нет живого Asus — эти проверки делаются вручную на Merlin после установки пакета.

Тот же чеклист встроен в справку: панель **Настройки → справка** / [`docs/promo/index.html#qa`](./promo/index.html#qa) / `http://LAN:1131/help/#qa`.

## Быстрый чеклист

```sh
surfgate pf          # NTP / WAN / TPROXY / Xray / XrayUI
surfgate sp          # скорость (Cloudflare + fallbacks)
surfgate dns         # DNS leak + IPv6 leak + webrtc_hint
surfgate st          # xray + panel
```

Панель: `http://<lan>:1131/` → **Настройки → connection**.

## Guest Wi‑Fi (`guest_vpn_mode`)

| Значение | Ожидание |
| --- | --- |
| `follow` | Те же MAC/LAN-правила, что у основной сети |
| `vpn` | Guest bridges (`br1`/`br2`/…) **всегда** в TPROXY, даже если LAN = selected/exclude |
| `direct` | Guest CIDR не попадают в transparent proxy |

Проверка: с телефона в guest SSID открыть whatismyip; при `vpn` — exit IP VPN, при `direct` — WAN ISP.

## Split bypass (домены)

Connection → **Split bypass**: `example.com, geosite:category-games`  
После Apply/Restart в конфиге Xray правило `surfgate-split-bypass` → `outboundTag: direct`.

```sh
jq '.routing.rules[]|select(.name=="surfgate-split-bypass")' /opt/etc/xray/ssurf/*.json
```

App/DPI split **не** поддерживается (нужен DPI на роутере).

## VPN-only / fail-closed

Connection → **VPN-only**: домены, которые должны ходить **только** через VPN.

1. Apply/Restart → правило `surfgate-vpn-lock` → `outboundTag: proxy` (первым в `routing.rules`).
2. Literal-домены попадают в ipset `SSURF_LOCK4` (и LOCK6) через dnsmasq `ipset=/…`.
3. Цепочка `SSURF_SVCLOCK`: unmarked → WAN к LOCK IP = **DROP** (в т.ч. ESTABLISHED).
4. `surfgate dn` (Stop): conntrack flush по LOCK IP + DROP остаётся armed; dnsmasq lock-строки сохраняются.
5. Проверка: с LAN к заблокированному сервису без VPN — таймаут/отказ, не ISP IP.

```sh
jq '.routing.rules[0]' /opt/etc/xray/ssurf/*.json
iptables -w -t filter -nvL SSURF_SVCLOCK
ipset list SSURF_LOCK4 | head
```

Рекомендуется `ipsec=redirect`. Для чистых `geosite:` тегов fail-closed по IP слабее (нет раскрытия geodata в LOCK) — пока Xray жив, routing всё равно гонит в VPN.

## Speedtest cron

Connection → **Авто по cron**: `6h` / `12h` / `24h`  
CRU id: `ssurf_speedtest`. Ручной прогон: `surfgate cron speedtest` или `surfgate sp`.

Статус: `/opt/share/ssurf/speedtest_status.json` (и зеркало в webdir).

## DNS / IPv6 / WebRTC

- DNS leak: сверка resolver probe с WAN DNS; нужен «DNS только через Xray».
- IPv6: при `ipv6_mode=block` публичный IPv6 exit → `ipv6_leaked=true`.
- WebRTC: **только с LAN-браузера** → [browserleaks.com/webrtc](https://browserleaks.com/webrtc) (роутер не эмулирует браузерный WebRTC).

## Ограничения окружения

- Speed/DNS зависят от доступности Cloudflare / ipleak / fallback URL **с роутера**.
- Нет e2e в GitHub Actions без железа — этот документ + unit-тесты `tests/backend/vpn_hardening.spec.sh` и `net_tests.spec.sh`.
