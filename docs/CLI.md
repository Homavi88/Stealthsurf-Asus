# CLI StealthSurf на роутере

После установки:

```sh
ssurf <команда>                 # короткое имя (рекомендуется)
stealthsurf <команда>           # полное имя
/jffs/scripts/stealthsurf …
```

Справка: `ssurf h` · Меню: `ssurf m`

## Короткие команды

| Коротко | Полное | Действие |
| --- | --- | --- |
| `up` / `on` | `start` | Запуск VPN |
| `dn` / `off` | `stop` | Остановка |
| `re` / `rs` | `restart` | Рестарт |
| `st` | `status` | JSON-статус |
| `sy` | `sync` | Sync с сайта + rebuild при изменениях |
| `ls` / `l` | `list` | Список конфигов |
| `ap` / `a` \<id\> | `apply` | Apply конфиг |
| `en` \<id\> | `enable` | Включить outbound |
| `dis` \<id\> | `disable` | Выключить outbound |
| `def` \<tag\> | `set-default` | Default outbound |
| `key` \<stlth_\> | `set-key` | API-ключ |
| `mode` \<m\> | `set-mode` | proxy / redirect / tproxy |
| `dns` \<m\> | `set-dns-mode` | OFF / BYPASS / REDIRECT |
| `rb` | `rebuild` | Пересобрать dataplane |
| `v` / `ver` | `version` | Версия |
| `cu` / `chk` | `check-update` | Проверить GitHub |
| `upd` [`-f`] | `update` | Обновить (с `-f` — force) |
| `uf` | `force-update` | Всегда latest |
| `lv` | `list-versions` | Список релизов + changelog |
| `iv` \<tag\> | `install-version` | Установить / откатить на tag |
| `d` / `dg` | `diag` | Диагностика |
| `p` / `proto` | `protocols` | Матрица протоколов |
| `log` | `logs` | Логи |
| `bak` | `backup` | Бэкап |
| `cl` | `clients` | Клиенты LAN |
| `dev` | `devices` | Устройства |
| `conn` | `connectivity` | Проверка связи |
| `xray` | `install-xray` | Поставить Xray |
| `geo` | `geodata` | Обновить geoip/geosite |
| `un --yes` | `uninstall --yes` | Полное удаление (без `--yes` отказ) |
| `doctor` | `doctor` | Восстановить UI / CLI symlink / хуки |
| `m` | `menu` | Интерактивное меню |

Полные имена (`start`, `check-update`, …) по-прежнему работают.

## Быстрый сценарий

```sh
ssurf key 'stlth_…'
ssurf sy
ssurf ap 101
ssurf mode redirect
ssurf up
ssurf st

# после смены настроек на сайте:
ssurf sy

ssurf cu && ssurf upd
ssurf lv                 # список релизов
ssurf iv v1.0.16         # откат на выбранную версию
ssurf dn
ssurf doctor          # если пропал UI/CLI
ssurf un --yes        # полное удаление
```

`sy` / autosync: тянут каталог API и пересобирают dataplane только при изменении включённых конфигов. Подробнее: [PROTOCOLS.md](./PROTOCOLS.md).
