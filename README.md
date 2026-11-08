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

WebUI: **VPN → StealthSurf**. CLI: `stealthsurf` / `ssurf`.

## StealthSurf API (1.1)

| Action | CLI | WebUI |
| --- | --- | --- |
| Save / add API key | `stealthsurf set-key stlth_…` / `add-key` | Account panel |
| Balances (RUB + referral) | `stealthsurf bal` | Balance table (+ browser CORS refresh) |
| Sync configs / locations / subs | `stealthsurf sync` | Sync catalog |
| Import config → outbound `ss-<id>` | `stealthsurf import-config <id>` | Import selected → Outbounds |

API base: `https://api.stealthsurf.net` (Bearer `stlth_…` keys).

Keys from 1.0.x (`/opt/etc/stealthsurf.conf`) are migrated on install when the new store is empty.

## Platform

This release is a branded fork of **XrayUI** (Vue 3 WebUI + shell backend): inbounds/outbounds,
routing, DNS, clients online, geodata, subscriptions, firewall/TPROXY, updates, etc.

Upstream project and license: see [ATTRIBUTION.md](./ATTRIBUTION.md) and [LICENSE](./LICENSE)
(CC BY-NC-SA 4.0, © Daniel Lavrushin / contributors).

## Build

```sh
pnpm install
pnpm run pack   # → packaged/asuswrt-merlin-stealthsurf.tar.gz
```

## Docs

- Provider: https://docs.stealthsurf.net  
- API: https://docs.stealthsurf.net/api  
- Upstream XrayUI: https://daniellavrushin.github.io/asuswrt-merlin-xrayui/
