# CLI StealthSurf на роутере

После установки доступны:

```sh
/jffs/scripts/stealthsurf <команда>
# или
stealthsurf <команда>          # symlink → /opt/bin/stealthsurf
```

Справка: `stealthsurf help`

## Управление сервисом

| Команда | Действие |
| --- | --- |
| `stealthsurf start` | Запуск Xray + firewall |
| `stealthsurf stop` | Остановка, снятие iptables/ip rule |
| `stealthsurf restart` | Рестарт VPN |
| `stealthsurf status` | JSON-статус |

## Обновление версии

| Команда | Действие |
| --- | --- |
| `stealthsurf version` | Установленная версия (+ latest из кэша) |
| `stealthsurf check-update` | Запрос к GitHub Releases → `version.json` |
| `stealthsurf update` | Если есть новее — скачать и установить |
| `stealthsurf update --force` | Всегда поставить latest с GitHub |
| `stealthsurf force-update` | То же, что `--force` |

То же в WebUI: **Проверить версию** / **Установить с GitHub** (шапка и вкладка «Режим / DNS»).

## Полное удаление с роутера

```sh
stealthsurf uninstall
# алиасы:
stealthsurf remove
stealthsurf purge
```

Удаляет: stop + firewall, хуки (`services-start`, `post-mount`, `nat-start`, `firewall-start`, `wan-start`, `dnsmasq.postconf`, `service-event`), cron, UI, `/jffs/scripts/stealthsurf`, `/jffs/addons/stealthsurf`, данные в `/opt/share/stealthsurf`, conf, hysteria-конфиги аддона. Бинарь Xray в `/opt` не трогается (может использоваться другими аддонами).

## Быстрый сценарий

```sh
stealthsurf set-key 'stlth_…'
stealthsurf sync
stealthsurf apply 101
stealthsurf set-mode redirect
stealthsurf start
stealthsurf status

stealthsurf check-update
stealthsurf update

stealthsurf stop
stealthsurf uninstall
```
