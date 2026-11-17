# Roadmap — SurfGate 1.4.x (standalone panel + XrayUI)

## Status

**1.4.0** — product brand **SurfGate**; own standalone panel on router IP port
**1131** (architecture analogous to official StealthSurf `stealthsurf-routerd`
on `:8800`), while keeping the Merlin VPN tab, XrayUI dataplane, and
StealthSurf provider API.

1.0.x shell/ASP addon remains archived under `legacy/v1.0/` for reference.

## Done

- [x] XrayUI Vue + shell platform + StealthSurf API control plane
- [x] Brand SurfGate / package `asuswrt-merlin-surfgate` / CLI `surfgate` / coexistence with stock XrayUI
- [x] PATCH / autofit / paid+cloud / traffic / autosync
- [x] Standalone panel `:1131` (BusyBox httpd + CGI bootstrap/api)
- [x] Optional dedicated `panel_ip` secondary alias on `br0`
- [x] Light panel UI (home status + settings sections)
- [x] Path isolation from official `/jffs/addons/stealthsurf`

## Next

- [ ] Router smoke: panel + redirect/tproxy + API sync next to official `:8800`
- [ ] Safer Web exposure of API keys
- [ ] Device-centric routing UI closer to official panel (per-client rules)
- [ ] Docs refresh (INSTALL / CLI) for SurfGate panel paths

## Upgrade note

`1.0.x → 1.1.0` replaces the custom ASP UI with the XrayUI-based SPA. Dataplane
paths and firewall marks follow XrayUI (`XRAYUI_*` ipsets / tables). Re-apply
transparent mode and routing after upgrade if you relied on 1.0.x `STEALTHSURF`
chains.

`1.3.x → 1.4.0` is a brand rename only: use CLI `surfgate` (aliases `ssurf`/`ss`
remain); package asset is `asuswrt-merlin-surfgate.tar.gz`.
