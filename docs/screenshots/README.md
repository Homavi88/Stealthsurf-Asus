# Screenshots

PNG-превью WebUI для README GitHub (layout как у XrayUI: FormTable-секции, кнопки справа).

| Файл | Содержание |
| --- | --- |
| `01-status-running.png` | Configuration + API keys |
| `02-catalog.png` | Outbounds / catalog |
| `03-routing.png` / `06-routing-builder.png` | Routing / конструктор правил |
| `07-routing-suggest.png` | Автоподсказки доменов |
| `04-mode-dns.png` | Mode / DNS |
| `05-xrayui-conflict.png` | Конфликт с XrayUI |
| `08-settings-modal.png` | Модалка Настройки (manage) |

Примеры в mock routing: ads→block, ru/private→direct, youtube/telegram/openai→ss-101, netflix→ss-205.

Переснять:

```sh
node tools/capture-ui-screenshots.mjs
```

Нужен Google Chrome (`/usr/local/bin/google-chrome`). Скрипт поднимает локальный Merlin-stub preview с mock JSON и пишет файлы сюда.
