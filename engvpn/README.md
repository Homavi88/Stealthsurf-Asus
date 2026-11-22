# EngVPN — Asuswrt-Merlin addon

Open Merlin installer/package modeled on StealthSurf’s `merlin.sh` + router tarball, without StealthSurf proprietary binaries or trademarks.

| | |
| --- | --- |
| Version | see [`VERSION`](./VERSION) |
| Panel | `http://<lan>:8790/` (password required) |
| Prefix | `/jffs/addons/engvpn` or `/tmp/mnt/<drive>/engvpn` |
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

## Package layout

```
sbin/engvpnd                 # CLI: serve | set-password | status | stop | update-check
share/engvpn/install.sh      # install | upgrade | uninstall
share/engvpn/service.sh      # start | stop | restart | check
share/engvpn/hook.sh         # Merlin user-script hooks
share/engvpn/netfilter.sh    # panel port + optional rule replay
share/engvpn/runtime/        # Node panel (open)
share/engvpn/files           # manifest
```

## Build & smoke (dev host)

```sh
cd engvpn
./build-package.sh          # → dist/*.tar.gz + feed/latest.json
./smoke-test.sh             # syntax, install, password, hooks, panel health, uninstall
```

## Parity vs StealthSurf (summary)

| Surface | EngVPN |
| --- | --- |
| Bootstrap + SHA-256 feed | yes (`merlin.sh`) |
| arm64 / armv7 keys | yes (same payload; cores fetch per-arch) |
| JFFS / USB prefix + disk/RAM checks | yes |
| Panel password at install | yes (`engvpnd set-password`) |
| Service + Merlin hooks | yes |
| Closed `stealthsurf-routerd` / `nfqws` / GRE / OpenFlux | **not shipped** — open Node panel + Xray/sing-box/mihomo downloads |
| Full transparent TPROXY / kill-switch | **gap** — SOCKS/HTTP edge + optional netfilter stub |

Details: project report `docs/engvpn-merlin-addon.md` in the EngVPN agent store / PR description.
