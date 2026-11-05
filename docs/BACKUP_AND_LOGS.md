# Backup конфигураций и логирование

## Backup

```sh
stealthsurf backup                 # ручной
stealthsurf backup "before-test"   # с заметкой
stealthsurf backups                # список (JSON)
stealthsurf restore stealthsurf-backup-YYYYMMDD-HHMMSS.tar.gz
```

В архив входят: `stealthsurf.conf`, `routing.json`, `outbounds.json`, `policies` (с IP устройств на момент backup), кэш configs/keys/subscriptions/locations, `xray.json`, `devices.json`, `manifest.json`.

- Авто-backup перед apply / сменой mode / policies / restore / update (`SS_AUTO_BACKUP=1`)
- Ночной backup в 03:00 (cru)
- Хранится последние `SS_BACKUP_KEEP` (по умолчанию 10) архивов в `/opt/share/stealthsurf/backups/`

## Логи

| Файл | Содержимое |
| --- | --- |
| `logs/activity.log` | действия: start/stop/apply/sync/firewall/policies + **ip=… mac=…** |
| `logs/errors.log` | WARN/ERROR |
| `logs/devices.log` | снимки LAN-клиентов (IP/MAC/name) |
| `logs/addon.log` | общий лог |
| `logs/xray-access.log` / `xray-error.log` | Xray |

```sh
stealthsurf logs activity 100
stealthsurf logs errors 50
stealthsurf logs devices 80
stealthsurf devices          # новый снимок LAN
stealthsurf clear-logs all
```

В WebUI: вкладки **Режим / DNS → Backup** и **Диагностика** (activity / devices / errors).
