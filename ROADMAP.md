# Roadmap — StealthSurf 1.1.x (XrayUI platform)

## Status

**1.1.0 beta** — full platform switch to
[asuswrt-merlin-xrayui](https://github.com/DanielLavrushin/asuswrt-merlin-xrayui) v0.71.0
plus StealthSurf API control plane (keys, balances, catalog, import).

1.0.x shell/ASP addon remains archived under `legacy/v1.0/` for reference.

## Done in 1.1.0 beta

- [x] Import XrayUI Vue + shell backend as the product platform
- [x] Brand as StealthSurf (`ADDON_TAG=stealthsurf`, menu tab, package name)
- [x] Version `1.1.0` with same release asset for in-place upgrade from 1.0.x
- [x] API keys / balances / sync / import-to-outbounds (`ss-<id>`)
- [x] Migrate keys from `/opt/etc/stealthsurf.conf` on install
- [x] CLI aliases `stealthsurf` / `ssurf`

## Next (post-beta)

- [ ] Router smoke on Merlin models (redirect/tproxy + API sync)
- [ ] Safer Web exposure of API keys (browser CORS balance without shipping full keys)
- [ ] PATCH config settings from UI (protocol/location) → rebuild
- [ ] Autosync cron for StealthSurf catalog fingerprint
- [ ] Optional simple-mode presets tailored to StealthSurf catalog
- [ ] Docs refresh (INSTALL / CLI) for 1.1 paths

## Upgrade note

`1.0.x → 1.1.0` replaces the custom ASP UI with the XrayUI-based SPA. Dataplane
paths and firewall marks follow XrayUI (`XRAYUI_*` ipsets / tables). Re-apply
transparent mode and routing after upgrade if you relied on 1.0.x `STEALTHSURF`
chains.
