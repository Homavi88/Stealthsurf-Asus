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
| `upd` [`-f`] | `update` | Обновить (с `-f` / `uf` — принудительно) |
| `uf` | `force-update` | Всегда скачать latest |
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
| `cfg` | `settings` | Показать настройки (JSON) |
| `setcfg` | `set-settings` | Применить JSON настроек |
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
ssurf uf                 # force: скачать latest даже если «уже актуально»
ssurf lv                 # список релизов
ssurf iv v1.0.16         # откат на выбранную версию
ssurf log activity 40    # лог шагов обновления (progress.*)
ssurf dn
ssurf doctor          # если пропал UI/CLI
ssurf un --yes        # полное удаление
```

Обновление в SSH показывает этапы `[1/7]…[7/7]` и пишет их в `/opt/share/stealthsurf/logs/activity.log`.  
Если `ssurf upd` пишет «Already up to date» — это нормально; переустановка: `ssurf uf`.  
Отключить прогресс: `SS_PROGRESS=0 ssurf upd`.

`sy` / autosync: тянут каталог API и пересобирают dataplane только при изменении включённых конфигов. Подробнее: [PROTOCOLS.md](./PROTOCOLS.md).
