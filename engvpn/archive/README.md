# Архив: Node-панель EngVPN (до 1.0.0)

До **1.0.0** панель EngVPN собиралась из `alfa-addon` + оверлеев (`overlays/*.mjs`, `overlays/public`) и запускалась через Entware **Node.js** (`run.mjs`).

С 1.0.0 runtime панели — статический бинарь **`engvpn-daemon`** (Rust, предпочтительно musl aarch64). Node **не** требуется для работы панели.

Здесь сохранены исходники прежнего стека для справки и сравнения:

| Путь | Что это |
| --- | --- |
| `node-overlays/` | Копия `engvpn/overlays/` на момент cutover |
| Upstream `alfa-addon/` в корне репозитория | Открытая база UI/runtime (не удаляем; больше не вендорится в пакет EngVPN) |

Скрипты Merlin (`service.sh`, `transparent.sh`, `dpi.sh`, …) остаются shell — их не архивировали.
