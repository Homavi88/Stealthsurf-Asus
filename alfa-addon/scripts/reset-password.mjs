#!/usr/bin/env node
/** Сброс пароля панели. Запуск из каталога аддона или с путём к нему. */
import {
  loadState,
  saveState,
  hashPassword,
  checkPassword,
  DEFAULT_PANEL_PASSWORD,
} from "../lib/state.mjs";

const next = String(process.argv[2] || DEFAULT_PANEL_PASSWORD).trim();
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
if (state.password.algo !== "pbkdf2-sha256") {
  console.error("ожидался algo=pbkdf2-sha256");
  process.exit(1);
}
console.log(`ok password=${next} algo=${state.password.algo}`);
