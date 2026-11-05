# Матрица моделей роутеров

Проверка на реальном железе. Отмечайте результаты после smoke-теста.

| Модель | Merlin | Entware | REDIRECT | TPROXY | Заметки |
| --- | --- | --- | --- | --- | --- |
| RT-AX88U | 3004+ | ✓ | ☐ | ☐ | aarch64 |
| RT-AX86U | 3004+ | ✓ | ☐ | ☐ | aarch64 |
| RT-AX68U | 3004+ | ✓ | ☐ | ☐ | aarch64 |
| RT-AC86U | 386+ | ✓ | ☐ | ☐ | aarch64 |
| RT-AC68U | 386+ | ✓ | ☐ | ☐ | armv7 — xray arm32-v7a |
| GT-AX6000 | 3004+ | ✓ | ☐ | ☐ | aarch64 |
| XT12 / GT-AXE16000 | 3004+ | ✓ | ☐ | ☐ | |

Критерии smoke-теста:

1. `curl …/install.sh | sh` успешен
2. Sync + apply + start
3. Клиент Wi‑Fi без прокси → IP ноды StealthSurf
4. `stealthsurf stop` → прямой интернет
5. Reboot → UI + firewall восстановлены
