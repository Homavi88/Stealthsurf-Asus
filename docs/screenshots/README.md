# Screenshots

PNG-превью WebUI для README GitHub.

| Файл | Содержание |
| --- | --- |
| `01-status-running.png` | Статус / ключи |
| `02-catalog.png` | Каталог подключений |
| `03-routing.png` / `06-routing-builder.png` | Конструктор правил с примерами |
| `07-routing-suggest.png` | Автоподсказки доменов |
| `04-mode-dns.png` | Режим / DNS |
| `05-xrayui-conflict.png` | Конфликт с XrayUI |

Примеры в mock routing: ads→block, ru/private→direct, youtube/telegram/openai→ss-101, netflix→ss-205.

Переснять:

```sh
node tools/capture-ui-screenshots.mjs
```

Нужен Google Chrome (`/usr/local/bin/google-chrome`). Скрипт поднимает локальный Merlin-stub preview с mock JSON и пишет файлы сюда.
