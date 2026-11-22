# EngVPN — Asuswrt-Merlin addon

Open Merlin installer/package modeled on StealthSurf’s `merlin.sh` + router tarball, without StealthSurf proprietary binaries or trademarks.

| | |
| --- | --- |
| Version | see [`VERSION`](./VERSION) (0.2.0+) |
| Panel | `http://<lan>:8790/` (password required) |
| Prefix | `/jffs/addons/engvpn` or `/tmp/mnt/<drive>/engvpn` |
| Transparent | `engvpnd transparent` — iptables REDIRECT / TPROXY, selective devices, kill-switch |
| Runtime | Node.js panel (vendored from `alfa-addon`, EngVPN-branded) + downloadable open cores |
| Does not touch | `/jffs/addons/stealthsurf` (`:8800`), `/jffs/addons/ssurf` (`:1131`), `/jffs/addons/alfa` (`:8788`) |

## Install on a router

Needs: Asuswrt-Merlin, JFFS custom scripts, root SSH, Entware Node (`opkg install node`), HTTPS curl.

```sh
curl -fsSL https://raw.githubusercontent.com/Homavi88/Stealthsurf-Asus/main/engvpn/merlin.sh | sh
```

Interactive install prompts for a panel password (8–128 chars). Non-interactive:

```sh
ENGVPN_PASSWORD='your-password' curl -fsSL …/engvpn/merlin.sh | sh
```

Override prefix: `ENGVPN_PREFIX=/tmp/mnt/USB/engvpn`.

## Transparent / selective VPN

```sh
# Edit /jffs/addons/engvpn/data/transparent.conf
# mode=all|selected|exclude|off  method=redirect|tproxy  killswitch=0|1
engvpnd transparent apply
engvpnd transparent status
```

Panel: `POST /api/invoke/transparent` with `{"action":"apply","mode":"all"}`.  
Xray gets a dokodemo inbound when mode ≠ `off`. No `stealthsurf-nfqws`.

## Update

```sh
engvpnd update-check
engvpnd update
```

Publish release assets: `./publish-release.sh` (dry-run) or `./publish-release.sh --push`.

## Package layout

```
sbin/engvpnd
share/engvpn/install.sh | service.sh | hook.sh
share/engvpn/transparent.sh | netfilter.sh | update.sh
share/engvpn/runtime/          # Node panel
share/engvpn/files             # manifest
```

## Build & smoke (dev host)

```sh
cd engvpn
./build-package.sh
./smoke-test.sh
```

## Parity vs remaining hard gaps

See project report and PR description. Hard gaps: closed routerd/GRE/OpenFlux/Ferrum/nfqws; Minisign; Entware Node; pixel-perfect StealthSurf cloud UI.
