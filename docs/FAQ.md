# FAQ

## Устройства в Wi‑Fi не идут через VPN

1. Режим должен быть `redirect` или `tproxy`, не `proxy`
2. `stealthsurf status` → `running: true`
3. `stealthsurf diag` — проверьте цепочку `STEALTHSURF` в iptables
4. На клиенте не должно быть своего системного VPN/прокси

## После reboot правил нет

Проверьте хуки:

- `/jffs/scripts/services-start` — `mount_ui` + `autostart`
- `/jffs/scripts/nat-start` и `firewall-start` — `firewall-restore`

JFFS custom scripts должны быть включены.

## Stop / uninstall ломает интернет?

`stealthsurf stop` и `uninstall` чистят цепочки `STEALTHSURF` и `ip rule`. Если интернет пропал — перезапустите firewall роутера (`service restart_firewall`) или reboot.

## После установки / старта пропал интернет

Частые причины (исправлено в **v1.0.14**):

1. Режим **redirect/tproxy** без живого Xray — LAN уходит в «чёрную дыру»
2. Entware `iptables` перехватывал системный iptables Merlin
3. Совпадение TPROXY mark/table с **xrayui** (`0x10000` / `77`) — теперь у нас `0x20000` / `78`
4. Не хватало исключений DHCP / LOCAL / DNAT

Срочно вернуть интернет:

```sh
ssurf mode proxy
ssurf dn          # stop + cleanup firewall
# или
ssurf doctor
```

Прозрачный режим включайте только после успешного sync/apply: `ssurf mode redirect` → `ssurf up`.

## Как сделать правило «YouTube → мой VPN»?

1. Включите конфиг на вкладке **Мои подключения** (появится `ss-<id>`)
2. **Routing** → тип `geosite` или `domain`
3. В поле matcher начните печатать `you` — выберите подсказку
4. Outbound = ваш `ss-<id>` → **Добавить** → **Сохранить routing + Apply**
5. При необходимости: **Обновить geoip/geosite**

То же для geoip (`ru` → direct) и списков доменов.

## Как увидеть «что нового» в обновлении?

При проверке версии (`ssurf cu` или кнопка в WebUI) аддон читает описание релиза с GitHub и показывает **модальное окно**:

- кратко по-русски (Новое / Исправления)
- ссылка на страницу релиза
- кнопка «Установить с GitHub»

То же окно открывается по кнопке **«Что нового»** на жёлтом баннере обновления.

## Как откатиться на другую версию?

В WebUI: **Update → versions / rollback** (или в Advanced → **Выбрать версию / откат**).

1. Откроется список релизов с GitHub (свежие и более старые)
2. Выберите нужный tag — ниже сразу покажутся изменения этой версии (Новое / Исправления)
3. Нажмите **Откатиться…** / **Обновить до…** / **Переустановить…**

CLI:

```sh
ssurf lv              # список версий + краткий changelog
ssurf iv v1.0.16      # установить / откатить на выбранный tag
ssurf iv v1.0.16 -f   # переустановить ту же версию принудительно
```

Перед сменой версии делается auto-backup. Откат качает именно выбранный release asset, без подмены на latest.

## Настройки (модальное окно)

Кнопка **Настройки** в блоке «Управление» открывает отдельное окно:

- **Автостарт** после reboot роутера и **watchdog**
- **Перезагрузка по плану** (daily / weekly / monthly / свой cron) — вызывает `/sbin/reboot`
- **Backup**: ночной cron 03:00, число хранимых копий, кнопки «Создать» / «Список»
- **GeoIP / GeoSite**: автообновление по расписанию + **URL базы** (скачиваются `geoip.dat` и `geosite.dat`)

CLI: `ssurf cfg` (показать), `ssurf setcfg '{"geodata_auto":true,"geodata_base":"https://…"}'`.

## Нагрузка на CPU / память роутера

StealthSurf рассчитан на слабые ARM (Merlin):

- **Xray** — основной процесс (как у xrayui); access-лог по умолчанию **выключен**
- **watchdog** раз в **10 мин** (pidfile + при необходимости firewall); ротация логов
- **autosync** раз в **15 мин** (curl + jq, без лишней работы если fingerprint не менялся)
- детект XrayUI: сначала pidfile, TTL-кэш 45 с — без обхода `/proc` на каждом тике
- `nat-start` / `firewall-start` не пересобирают правила, если WAN fingerprint не изменился
- UI **не** поллит в фоне — только при открытии страницы / после действий

Если роутер «задыхается»: `ssurf mode proxy`, отключите transparent, проверьте `top` на процесс `xray`.

## Можно ли вместе с XrayUI?

**Нет, одновременно нельзя.** С v1.0.15 StealthSurf:

- детектит работающий XrayUI (`/var/run/xray.pid`, процесс с `config.json`, цепочка `XRAYUI`)
- **блокирует Старт / Рестарт / autostart / watchdog**, пока XrayUI активен
- показывает красный баннер в WebUI: «Конфликт с XrayUI»

Mark/table у нас отдельные (`0x20000`/`78` vs `0x10000`/`77`), но два transparent proxy всё равно рвут LAN.

Порядок:

1. В XrayUI → Stop  
2. В StealthSurf → Старт  
(или наоборот — только один dataplane)

Если XrayUI только установлен, но остановлен — StealthSurf можно запускать (жёлтый hint в статусе).

## Нет левого меню / шапки Asus на странице StealthSurf

С v1.0.22 `app.js` больше не перезаписывает jQuery `$` — из‑за этого Merlin `show_menu()` падал в `$.inArray` и **не рисовал левое меню** (шапка TopBanner при этом могла быть). Вкладка **VPN → StealthSurf** вставляется в `menuTree.js` через awk (BusyBox без `\s`).

С v1.0.23 каркас страницы совпадает с XrayUI: стоковый `.content` 998px (`middown_bg`), `FormTitle` 760px, без `width:100%` на таблице — иначе справа оставалась чёрная пустота.

## WebUI слишком длинный / ничего не помещается на телефоне

С **v1.0.26–1.0.27** интерфейс как у XrayUI:

- **Configuration** — статус, sync, **API keys** (manage → модалка), general options, **Backup / Logs** (manage → модалка), update
- **Outbounds / catalog** — компактный список с тегами протокола; **e** открывает модалку настроек (location/protocol/PATCH)
- **Routing** — один пункт manage → модалка правил
- **Advanced** — policies, mode/DNS, diagnostics в модалках

На узком экране таблицы в модалках прокручиваются горизонтально.

## Список версий / «Проверить на GitHub» показывает Apply и проценты, но ничего не загружает

До **v1.0.25** кнопки `versions` / `checkupdate` шли через Merlin `start_apply.htm` + `action_script` (как сохранение настроек). Экран «применение настроек» с процентами перекрывал модалку, страница перезагружалась, а ответ часто терялся — список релизов казался пустым.

Как в XrayUI: проверка и список релизов теперь читаются **из браузера** через GitHub API прямо в оверлей-модалке (loading / error внутри модалки). `start_apply` используется только для реальной установки/отката версии.

## API-ключ не сохраняется / пустой список ключей в WebUI

Две отдельные поломки (обе закрыты):

1. **v1.0.23** — хук `service-event` смотрит на `$2` (`stealthsurf_…`), как XrayUI. Раньше требовался `$1=start`, а UI слал `stealthsurf_setkey` без `start_` — Merlin вызывал хук с пустым `$1`, и setkey не запускался.
2. **v1.0.24** — даже когда хук уже срабатывал, payload был пустой. Merlin `write_custom_settings()` пишет `amng_custom` только в `/jffs/addons/custom_settings.txt` как **плоские строки** и **не** делает `nvram set amng_custom`. Вложенный JSON `{stealthsurf:{api_key:…}}` теряется (`json_object_get_string` для object → NULL). Теперь UI кладёт действие в строку `stealthsurf_payload`, а backend читает её из `custom_settings.txt` (как XrayUI с `xray_payload*`).

После обновления:

```sh
ssurf upd -f
# или: /jffs/scripts/stealthsurf doctor
```

Затем выйти/войти в WebUI и снова **Сохранить и проверить**. Через SSH по-прежнему: `ssurf key 'stlth_…'`.

Проверка, что ключ записался:

```sh
cat /opt/share/stealthsurf/api_keys.json
grep SS_API_KEY /opt/etc/stealthsurf.conf
cat /www/user/stealthsurf/stealthsurf-response.json
```

## Пропала вкладка VPN → StealthSurf и/или команда `ssurf`

Частые причины:

1. **Неудачное обновление** (старые версии удаляли файлы до проверки архива) — с v1.0.12 update атомарный.
2. **Entware на USB** временно не смонтирован → `/opt/bin/ssurf` «не найден», хотя скрипт на JFFS жив.
3. Случайный `ssurf rm` / `uninstall` в старых версиях (алиас `rm` убран; нужен `ssurf un --yes`).

Восстановление:

```sh
/jffs/scripts/stealthsurf doctor
# если скрипта тоже нет — переустановите one-liner из README
```

Затем выйти из WebUI и зайти снова.

## Протокол «недоступен» / apply не работает

- **vless / trojan / ss / openflux / http / socks5 / wg** — через Xray (часто из `connection_url`; OpenFlux — proxy outbound в `xray_config`)
- **hysteria2** — клиент скачивается при apply (или положите `/opt/sbin/hysteria`)
- **amnezia-wg-2** — нужен `awg-quick` / AmneziaWG на роутере

Матрица: `stealthsurf protocols` или бейджи в UI. Подробнее: [PROTOCOLS.md](./PROTOCOLS.md).

## Изменил настройки на сайте StealthSurf — на роутере старый протокол

1. Нажмите **Синхронизировать** в UI или `stealthsurf sync`
2. Аддон сравнит fingerprint включённых конфигов (`connection_url`, protocol, location, `xray_config`…)
3. При изменениях автоматически сделает rebuild + soft-restart Xray
4. Autosync каждые **15 минут** делает то же самое

Если VPN ещё не запускали — sync только обновит кэш; затем `apply` / `start`.

## Rate-limit API

StealthSurf: ~60 запросов/мин. При HTTP 429 подождите и повторите sync.

## Несколько API-ключей

`stealthsurf add-key 'stlth_…' 'work'` — sync объединяет конфиги всех ключей в один каталог.
