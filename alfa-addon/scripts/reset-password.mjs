#!/usr/bin/env node
/** В 0.1.2+ панель открыта без пароля. Скрипт оставлен для совместимости install.sh. */
import { OPEN_PANEL } from "../lib/catalog.mjs";
import {
  loadState,
  saveState,
  hashPassword,
  checkPassword,
  DEFAULT_PANEL_PASSWORD,
} from "../lib/state.mjs";

if (OPEN_PANEL) {
  const state = loadState();
  state.failedLogins = 0;
  state.lockedUntil = 0;
  // очищаем блокировки; хеш не обязателен для входа
  if (!state.password?.hash) state.password = hashPassword(DEFAULT_PANEL_PASSWORD);
  saveState(state, true);
  console.log("ok openAccess=true (пароль для входа не нужен)");
  process.exit(0);
}

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
console.log(`ok password=${next} algo=${state.password.algo}`);
