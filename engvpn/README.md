# EngVPN — аддон для Asuswrt-Merlin

Открытый VPN-аддон для Merlin с установкой и поверхностью, близкой к StealthSurf. Собран только из открытых компонентов (панель на Node, загружаемые Xray / sing-box / mihomo). **Не** содержит проприетарных бинарников и торговых марок StealthSurf.

| | |
| --- | --- |
| Версия | **0.2.0** ([`VERSION`](./VERSION)) |
| Панель | `http://<lan_ip>:8790/` (нужен пароль) |
| Префикс установки | `/jffs/addons/engvpn` или `/tmp/mnt/<USB>/engvpn` |
| CLI | `engvpnd` |
| Изоляция | Не трогает SurfGate `:1131`, официальный StealthSurf `:8800` и alfa `:8788` |

Релиз: [engvpn-0.2.0](https://github.com/Homavi88/Stealthsurf-Asus/releases/tag/engvpn-0.2.0)

---

## Требования

1. **Asuswrt-Merlin** с включёнными пользовательскими скриптами JFFS  
2. **Entware** (`amtm`) и **Node.js**: `opkg update && opkg install node`  
3. Root-доступ по SSH и HTTPS-клиент (`curl`)  
4. Достаточно места на JFFS (или USB с ext2/3/4)

## Установка

```sh
curl -fsSL https://raw.githubusercontent.com/Homavi88/Stealthsurf-Asus/main/engvpn/merlin.sh | sh
```

Установщик запросит пароль панели (8–128 символов), скачает пакет под ваш CPU (`merlin-aarch64` / `merlin-armv7`), проверит **SHA-256** и запустит сервис.

Без интерактива:

```sh
ENGVPN_PASSWORD='your-password' curl -fsSL https://raw.githubusercontent.com/Homavi88/Stealthsurf-Asus/main/engvpn/merlin.sh | sh
```

Опционально:

| Переменная | Назначение |
| --- | --- |
| `ENGVPN_PREFIX` | Путь установки (например `/tmp/mnt/USB/engvpn`) |
| `ENGVPN_LOCAL_PACKAGE` | Путь к локальному `.tar.gz` (без скачивания) |
| `ENGVPN_FEED` | Другой URL ленты (feed) |

Откройте панель:

```text
http://192.168.50.1:8790/
```

(подставьте IP роутера в LAN). Войдите с выбранным паролем.

## Повседневное использование

```sh
engvpnd status
engvpnd transparent status
engvpnd update-check
engvpnd update                 # самообновление из feed (SHA-256)
```

Сервис:

```sh
/jffs/addons/engvpn/share/engvpn/service.sh start|stop|restart|check
```

### Прозрачный / выборочный VPN

Правьте `/jffs/addons/engvpn/data/transparent.conf`:

```ini
mode=all          # off | all | selected | exclude
method=redirect   # redirect (по умолчанию) | tproxy
port=12345
killswitch=0
```

Список устройств (по желанию): `data/devices.select` (IP или MAC, по одному на строку). Затем:

```sh
engvpnd transparent apply
```

Использует открытый **iptables** REDIRECT (или TPROXY, если доступен) и dokodemo inbound в Xray — не `stealthsurf-nfqws`.

## Удаление

```sh
sh /jffs/addons/engvpn/share/engvpn/install.sh uninstall
```

## Сборка / smoke (для разработчиков)

```sh
cd engvpn
./build-package.sh
./smoke-test.sh
./publish-release.sh          # dry-run
./publish-release.sh --push   # GitHub Release engvpn-$VERSION
```

## Отличия от официального StealthSurf

| Upstream | EngVPN |
| --- | --- |
| Закрытый `stealthsurf-routerd` / GRE / OpenFlux / Ferrum | Не поставляется — открытая панель Node + публичные ядра |
| `stealthsurf-nfqws` | Не поставляется — маршрутизация через iptables + dokodemo |
| Подписи Minisign | Только HTTPS + SHA-256 |
| Статический демон (без Entware) | Нужен Entware **Node** |

Подробнее: отчёт по проекту и [PR #152](https://github.com/Homavi88/Stealthsurf-Asus/pull/152).
