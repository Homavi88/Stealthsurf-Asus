# Routing: домен → конкретный VPN-конфиг

Каждый включённый StealthSurf config становится outbound с тегом `ss-<id>`.

## WebUI: конструктор правил

Вкладка **Routing**:

1. Выберите тип (`domain` / `geosite` / `geoip` / …)
2. Выберите outbound — VPN из API-каталога (`ss-<id>`) или `direct` / `block`
3. Введите matcher — при вводе домена/категории появляются **подсказки** из списка
4. **Добавить в список** → **Сохранить routing + Apply**

Подсказки:

- **domain** — популярные сайты (youtube.com, telegram.org, …)
- **geosite** — категории Loyalsoldier (`youtube`, `category-ru`, `category-ads-all`, …)
- **geoip** — `private`, `ru`, `cn`, `us`, …

Если домен есть в списке — подсказка подсвечивается; своё значение тоже можно ввести.

## Правила (JSON)

```json
[
  {
    "name": "netflix",
    "type": "geosite",
    "matcher": "netflix",
    "outbound": "ss-101",
    "priority": 10
  },
  {
    "name": "example",
    "type": "domain",
    "matcher": "example.com",
    "outbound": "ss-205",
    "priority": 20
  },
  {
    "name": "private",
    "type": "geoip",
    "matcher": "private",
    "outbound": "direct",
    "priority": 5
  }
]
```

Типы matcher: `domain` | `full` | `keyword` | `regexp` | `geosite` | `geoip` | `ip` | `cidr`.  
Outbound: `ss-<id>` | `direct` | `block`.

Трафик без спец. правила идёт в **default outbound**.

## Пресеты

```sh
stealthsurf preset all-vpn 205
stealthsurf preset ru-direct 205
stealthsurf preset streaming-split 205 101
stealthsurf preset block-ads 205
```

## Валидация

Нельзя сослаться на выключенный/удалённый `ss-<id>` — `set-routing` / rebuild вернёт ошибку.

## Geodata

```sh
stealthsurf geodata
# или кнопка «Обновить geoip/geosite» в WebUI
```

Файлы: `/opt/sbin/geoip.dat`, `/opt/sbin/geosite.dat` (репозиторий [Loyalsoldier/v2ray-rules-dat](https://github.com/Loyalsoldier/v2ray-rules-dat)).
