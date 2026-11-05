# Установка StealthSurf UI (Asuswrt-Merlin)

## Требования

- Asuswrt-Merlin `384.15+` / `3006.102.1+`
- JFFS custom scripts = Yes
- Entware уже установлен через `amtm`

## One-liner

```sh
curl -fsSL https://raw.githubusercontent.com/Homavi88/Stealthsurf-Asus/main/install.sh | sh
```

Установщик предпочитает пакет из **GitHub Releases**, затем fallback на `packaged/` в репозитории.

## После установки

1. Выйти из WebUI и зайти снова → **VPN → StealthSurf**
2. Вставить API-ключ → Синхронизировать
3. Включить нужные конфиги как outbounds, выбрать default
4. Режим: `redirect` (или `tproxy` если есть `xt_TPROXY`)
5. Старт

## CLI

Полный список: [CLI.md](./CLI.md) или `stealthsurf help`.

```sh
stealthsurf set-key 'stlth_…'
stealthsurf sync
stealthsurf apply <config_id>
stealthsurf set-mode redirect
stealthsurf start
stealthsurf stop
stealthsurf restart
stealthsurf status
stealthsurf check-update    # проверка GitHub
stealthsurf update          # установка, если есть новее
stealthsurf update --force  # всегда latest
stealthsurf diag
```

## Обновление из WebUI

VPN → StealthSurf → **Проверить версию** / баннер **Установить обновление** (или вкладка «Режим / DNS»).

## Удаление (полное)

```sh
stealthsurf uninstall
# или: stealthsurf remove | stealthsurf purge
```

Очищает iptables/ip rule, UI, хуки, cron, данные и скрипт аддона.
