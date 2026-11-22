/**
 * Точка входа службы. SIGHUP глушим ДО загрузки панели —
 * иначе curl|sh успевает убить process до process.on в server.mjs.
 */
try {
  process.on("SIGHUP", () => {});
} catch {
  /* ignore */
}

const fs = await import("node:fs");
if (process.env.ALFA_PID_FILE) {
  try {
    fs.writeFileSync(process.env.ALFA_PID_FILE, `${process.pid}\n`);
  } catch {
    /* ignore */
  }
}

const { start } = await import("./server.mjs");
const { PANEL_PORT } = await import("./lib/catalog.mjs");

start().then(() => {
  console.log(`StealthSurf alfa http://0.0.0.0:${PANEL_PORT} openAccess=true`);
}).catch((err) => {
  console.error(err);
  process.exit(1);
});
