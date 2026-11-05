# Сравнение с asuswrt-merlin-xrayui (для корректной работы на роутере)

Паттерны dataplane взяты из [xrayui](https://github.com/DanielLavrushin/asuswrt-merlin-xrayui); код не копируется целиком.

## Что обязательно для Merlin (сделано у нас)

| Паттерн xrayui | StealthSurf |
| --- | --- |
| `post-mount` startup (Entware на USB) | `stealthsurf startup` в `post-mount` |
| `nat-start` / `firewall-start` restore | `firewall-restore` |
| `wan-start` | `wan-up` |
| `dnsmasq.postconf` | `dnsmasq-configure` |
| `service-event` UI bridge | есть |
| JFFS scripts check | `ss_check_jffs_ready` |
| deps: curl jq iptables ipset flock | ставятся при install |
| WAN iface RETURN | `ss_fw_exclude_wan_ifaces` |
| TPROXY mark + local table + DIVERT/socket | есть |
| TCPMSS clamp | есть |
| desired-state для watchdog | `/tmp/stealthsurf.desired` |
| autostart delay / wait network | `SS_STARTUP_DELAY` |
| ip_forward / src_valid_mark | `ss_sysctl_dataplane` |
| restore firewall if missing while running | watchdog + start path |
| geoip/geosite | `stealthsurf geodata` |

## Намеренно не переносим (не нужны для StealthSurf UX)

- b4sni / rtls-scanner / reality helpers — диагностика xrayui
- subscriptions URL parser — у нас StealthSurf API catalog
- tun.sh full TUN mode — у нас REDIRECT/TPROXY
- am_settings custom_settings.txt — свой conf + JSON stores

## Рекомендуемые настройки на роутере

1. JFFS custom scripts = Yes, reboot  
2. Entware через amtm  
3. Режим аддона: **redirect** (или **tproxy** если есть `xt_TPROXY`)  
4. После sync: apply конфиг → Старт  
5. Проверка: `stealthsurf diag` и IP клиента Wi‑Fi = нода StealthSurf  

## Быстрая диагностика «не идёт через VPN»

```sh
stealthsurf status
stealthsurf logs activity 50
iptables -t nat -S STEALTHSURF
iptables -t mangle -S STEALTHSURF
lsmod | grep -i tproxy
cat /tmp/stealthsurf.desired
```
