# EngVPN — Asuswrt-Merlin addon

Open-source Merlin VPN addon with a StealthSurf-comparable **install path** and runtime surface. Built from open components only (Node panel, downloadable Xray / sing-box / mihomo). Does **not** ship StealthSurf proprietary binaries or trademarks.

| | |
| --- | --- |
| Version | **0.2.0** ([`VERSION`](./VERSION)) |
| Panel | `http://<lan_ip>:8790/` (password required) |
| Install prefix | `/jffs/addons/engvpn` or `/tmp/mnt/<USB>/engvpn` |
| CLI | `engvpnd` |
| Isolation | Leaves SurfGate `:1131`, official StealthSurf `:8800`, and alfa `:8788` alone |

Release: [engvpn-0.2.0](https://github.com/Homavi88/Stealthsurf-Asus/releases/tag/engvpn-0.2.0)

---

## Requirements

1. **Asuswrt-Merlin** with JFFS custom scripts enabled  
2. **Entware** (`amtm`) and **Node.js**: `opkg update && opkg install node`  
3. Root SSH and an HTTPS client (`curl`)  
4. Enough free space on JFFS (or an ext2/3/4 USB drive)

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/Homavi88/Stealthsurf-Asus/main/engvpn/merlin.sh | sh
```

The installer asks for a panel password (8–128 characters), downloads the package for your CPU (`merlin-aarch64` / `merlin-armv7`), verifies **SHA-256**, and starts the service.

Non-interactive:

```sh
ENGVPN_PASSWORD='your-password' curl -fsSL https://raw.githubusercontent.com/Homavi88/Stealthsurf-Asus/main/engvpn/merlin.sh | sh
```

Optional:

| Variable | Meaning |
| --- | --- |
| `ENGVPN_PREFIX` | Install path (e.g. `/tmp/mnt/USB/engvpn`) |
| `ENGVPN_LOCAL_PACKAGE` | Path to a local `.tar.gz` (skip download) |
| `ENGVPN_FEED` | Override feed URL |

Open the panel:

```text
http://192.168.50.1:8790/
```

(use your LAN IP). Sign in with the password you chose.

## Everyday use

```sh
engvpnd status
engvpnd transparent status
engvpnd update-check
engvpnd update                 # self-update from the feed (SHA-256)
```

Service:

```sh
/jffs/addons/engvpn/share/engvpn/service.sh start|stop|restart|check
```

### Transparent / selective VPN

Edit `/jffs/addons/engvpn/data/transparent.conf`:

```ini
mode=all          # off | all | selected | exclude
method=redirect   # redirect (default) | tproxy
port=12345
killswitch=0
```

Optional device list: `data/devices.select` (one IP or MAC per line). Then:

```sh
engvpnd transparent apply
```

Uses open **iptables** REDIRECT (or TPROXY when available) plus a dokodemo inbound in Xray — not `stealthsurf-nfqws`.

## Uninstall

```sh
sh /jffs/addons/engvpn/share/engvpn/install.sh uninstall
```

## Build / smoke (developers)

```sh
cd engvpn
./build-package.sh
./smoke-test.sh
./publish-release.sh          # dry-run
./publish-release.sh --push   # GitHub Release engvpn-$VERSION
```

## Gaps vs official StealthSurf

| Upstream | EngVPN |
| --- | --- |
| Closed `stealthsurf-routerd` / GRE / OpenFlux / Ferrum | Not shipped — open Node panel + public cores |
| `stealthsurf-nfqws` | Not shipped — routing via iptables + dokodemo |
| Minisign signatures | HTTPS + SHA-256 only |
| Static daemon (no Entware) | Needs Entware **Node** |

More detail: project report and [PR #152](https://github.com/Homavi88/Stealthsurf-Asus/pull/152).
