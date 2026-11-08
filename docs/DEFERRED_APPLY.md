# Правило: Deferred Apply («Применить» внизу)

Все **настройки** в WebUI ставятся в очередь и применяются на роутер **только** после кнопки **«Применить»** на главной странице. Кнопка **«Отменить»** сбрасывает очередь без записи на роутер; список изменений виден под кнопками.

Это сделано специально: Merlin на каждый `triggerService` показывает экран «Apply / Подождите», а значение из модалки часто **не** оказывается тем, что пользователь хотел сохранить.

## Обязательно для новых пунктов настроек

1. Добавьте action в `SS_PENDING_CONFIG_ACTIONS` в `src/ui/app.js`.
2. В обработчике кнопки вызывайте только:

   ```js
   queuePending(slot, action, payload, "Человекочитаемая метка");
   ```

3. **Запрещено** для сохранения настроек:

   ```js
   triggerService("setsettings", payload); // и любой другой config-action
   ```

4. Проверка: `sh tools/test-deferred-apply.sh` (CI).

## Что считать настройкой (очередь)

| Примеры | Action |
| --- | --- |
| API-ключи | `setkey` / `addkey` / `removekey` |
| Режим / DNS | `setmode` / `setdnsmode` |
| Routing / policies | `setrouting` / `preset` / `setpolicies` |
| Outbounds / apply config | `setdefault` / `setoutbounds` / `enableoutbound` / `disableoutbound` / `apply` / `updatesettings` |
| Модалка «Настройки» (автостарт, backup prefs, geodata schedule) | `setsettings` |

## Что может быть сразу (operational)

`start` / `stop` / `restart` / `sync` / `update` / `backup` / `restore` / `geodata` / `diag` / `logs` / `connectivity` / `testconfig` / `installxray` / …

Мягкие пути **без** Merlin-оверлея (browser fetch): `checkupdate`, баланс API-ключей.

## Анти-паттерн

Новая кнопка в модалке настроек, которая сразу делает `triggerService(...)` «чтобы проверить» и при этом должна сохранить поля — так **нельзя**. Сначала очередь, проверка без submit (или CLI на роутере после Apply).
