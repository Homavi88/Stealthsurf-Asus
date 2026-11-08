# StealthSurf for Asuswrt-Merlin · 1.1.x beta

VPN control panel for Asus routers (Merlin / Entware), rebuilt on the
[asuswrt-merlin-xrayui](https://github.com/DanielLavrushin/asuswrt-merlin-xrayui) platform
with StealthSurf API-key features (balance, connection catalog, import into Xray outbounds).

**Version:** `1.1.0` (beta channel) — upgrades from the 1.0.x addon via the same package name
`asuswrt-merlin-stealthsurf.tar.gz`.

## Install / upgrade

Requires JFFS custom scripts + Entware.

```sh
curl -fsSL https://raw.githubusercontent.com/Homavi88/Stealthsurf-Asus/main/install.sh | sh
```

Or from a GitHub Release asset (also what the in-UI updater downloads):

```sh
wget -O /tmp/asuswrt-merlin-stealthsurf.tar.gz \
  https://github.com/Homavi88/Stealthsurf-Asus/releases/latest/download/asuswrt-merlin-stealthsurf.tar.gz \
&& rm -rf /jffs/addons/stealthsurf \
&& tar -xzf /tmp/asuswrt-merlin-stealthsurf.tar.gz -C /jffs/addons \
&& mv /jffs/addons/stealthsurf/stealthsurf /jffs/scripts/stealthsurf \
&& chmod 0755 /jffs/scripts/stealthsurf \
&& sh /jffs/scripts/stealthsurf install
```

WebUI: **VPN → StealthSurf**. CLI: `ssurf` / `ss` / `stealthsurf` (`ssurf h` · `ssurf m`).

## StealthSurf API (1.1)

| Action | CLI | WebUI |
| --- | --- | --- |
| Save / add API key | `ssurf key stlth_…` / `ssurf addk` | Account panel |
| Balances (RUB + referral) | `ssurf bal` | Balance table (+ browser CORS refresh) |
| Sync configs / locations / subs | `ssurf sy` · `ssurf ls` | Sync catalog |
| Import config → outbound `ss-<id>` | `ssurf ap <id>` / `ssurf ic <id>` | Import selected → Outbounds |
| Start / stop / restart / status | `ssurf up` · `dn` · `re` · `st` | Server controls |

API base: `https://api.stealthsurf.net` (Bearer `stlth_…` keys).

Keys from 1.0.x (`/opt/etc/stealthsurf.conf`) are migrated on install when the new store is empty.

## Platform

This release is a branded fork of **XrayUI** (Vue 3 WebUI + shell backend): inbounds/outbounds,
routing, DNS, clients online, geodata, subscriptions, firewall/TPROXY, updates, etc.

Upstream project and license: see [ATTRIBUTION.md](./ATTRIBUTION.md) and [LICENSE](./LICENSE)
(CC BY-NC-SA 4.0, © Daniel Lavrushin / contributors).

## Coexistence with stock XrayUI (1.1.1+)

StealthSurf keeps its own state so it can sit beside stock XrayUI on one router:

| Resource | StealthSurf | Stock XrayUI |
| --- | --- | --- |
| Profile JSON | `/opt/etc/xray/stealthsurf/config.json` | `/opt/etc/xray/config.json` |
| Addon conf | `/opt/etc/stealthsurf.conf` | `/opt/etc/xrayui.conf` |
| Merlin settings | `stealthsurf_*` | `xray_*` |
| PID | `/var/run/stealthsurf-xray.pid` | `/var/run/xray.pid` |
| Firewall | chains `STEALTHSURF*`, mark `0x20000`, table `78` | `XRAYUI*`, `0x10000`, `77` |
| Custom geodata | `/opt/sbin/stealthsurf`, `ext:stealthsurf:` | `/opt/sbin/xrayui`, `ext:xrayui:` |

Still shared (single binary/dat on the router): `/opt/sbin/xray`, community `geoip.dat` / `geosite.dat`.
Do not run both addons’ transparent proxy at the same time.

## Build

```sh
pnpm install
pnpm run pack   # → packaged/asuswrt-merlin-stealthsurf.tar.gz
```

## Docs

- Provider: https://docs.stealthsurf.net  
- API: https://docs.stealthsurf.net/api  
- Upstream XrayUI: https://daniellavrushin.github.io/asuswrt-merlin-xrayui/
