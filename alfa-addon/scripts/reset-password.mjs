#!/usr/bin/env node
/** Сброс пароля панели на alfa. Запуск из каталога аддона или с путём к нему. */
import { loadState, saveState, hashPassword, checkPassword } from "../lib/state.mjs";

const next = String(process.argv[2] || "alfa");
if (next.length < 4) {
  console.error("пароль короче 4 символов");
  process.exit(1);
}
const state = loadState();
state.password = hashPassword(next);
state.failedLogins = 0;
state.lockedUntil = 0;
state.sessions = {};
saveState(state, true);
if (!checkPassword(next, state.password)) {
  console.error("хеш не сверился после записи");
  process.exit(1);
}
console.log(`ok password=${next}`);
