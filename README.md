# StealthSurf UI for Asuswrt-Merlin

Аддон для роутеров на **Asuswrt-Merlin**: StealthSurf — провайдер VPN, а весь интерфейс и перенастройка живут на роутере через ваш API-ключ `stlth_…`.

## Как это устроено

```text
Браузер (LAN) → VPN → StealthSurf (WebUI на роутере)
                         │
                         │  Bearer stlth_…
                         ▼
                   api.stealthsurf.net
                         │  connection_url
                         ▼
              Xray (Entware) + маршрутизация
```

- API-ключ хранится только на роутере (`/opt/etc/stealthsurf.conf`).
- Список конфигов, смена локации/протокола и Apply выполняются из UI/CLI.
- Dataplane MVP: протоколы на базе Xray (`vless`, `trojan`, `shadowsocks-2022`).

Паттерн установки и вкладки VPN взят как образец из [asuswrt-merlin-xrayui](https://github.com/DanielLavrushin/asuswrt-merlin-xrayui); код аддона — самостоятельный.

## Требования

- Asuswrt-Merlin `384.15+` / `3006.102.1+`
- JFFS custom scripts включены
- **Entware уже установлен** через `amtm` (установщик аддона Entware **не** ставит — только проверяет)

## Установка одной командой

На роутере по SSH (Entware должен быть уже установлен):

```sh
curl -fsSL https://raw.githubusercontent.com/Homavi88/Stealthsurf-Asus/main/install.sh | sh
```

Альтернатива без curl:

```sh
wget -qO- https://raw.githubusercontent.com/Homavi88/Stealthsurf-Asus/main/install.sh | sh
```

Что делает установщик:

1. Проверяет `/jffs` и что Entware есть (`/opt` + `opkg`); если Entware нет — **останавливается** с понятной ошибкой  
2. Ставит зависимости через `opkg` (`curl`, `jq`, `ca-certificates`, …)  
3. Скачивает пакет аддона с GitHub (`packaged/` или Releases)  
4. Раскладывает файлы в `/jffs/addons/stealthsurf` и `/jffs/scripts/stealthsurf`  
5. Запускает `stealthsurf install` (UI-вкладка, хуки)

После установки: выйти из WebUI и зайти снова → **VPN → StealthSurf**.

Удаление:

```sh
stealthsurf uninstall
```

## Быстрый старт в UI

1. Вставьте API-ключ из консоли StealthSurf (Profile → API Keys).
2. **Проверить ключ** → **Синхронизировать конфиги**.
3. Выберите конфиг → при необходимости смените локацию/протокол → **Применить**.
4. **Старт**.

## CLI

```sh
stealthsurf version
stealthsurf set-key 'stlth_........_........................'
stealthsurf sync                 # GET /configs → кэш на роутере
stealthsurf list
stealthsurf apply <config_id>    # connection_url → xray.json + restart
stealthsurf update-settings <config_id> '{"location_id":5,"protocol":"vless"}'
stealthsurf start|stop|restart|status
stealthsurf uninstall
```

## Сборка из исходников

```sh
npm install
npm run build
# артефакты в dist/: stealthsurf, index.asp, app.js
```

## MVP / дальше

| MVP | Позже |
| --- | --- |
| API-ключ, sync, apply | Hysteria2, WireGuard / AWG |
| Смена protocol/location | Сборные подписки |
| Xray start/stop | Split-tunnel по клиентам |
| Вкладка VPN | Локальный REST для HA / AI |

## Документация провайдера

- [docs.stealthsurf.net](https://docs.stealthsurf.net)
- [API](https://docs.stealthsurf.net/api)
- [Методы configs](https://docs.stealthsurf.net/api/methods/configs)
