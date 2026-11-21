import http from "node:http";
import { readFileSync, existsSync } from "node:fs";
import { join, extname, normalize, sep } from "node:path";
import { pathToFileURL } from "node:url";
import { createRuntime } from "./lib/runtime.mjs";
import { PANEL_PORT } from "./lib/catalog.mjs";
import { ROOT } from "./lib/state.mjs";

const PUBLIC = join(ROOT, "public");
const TYPES = {
  ".html": "text/html; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".svg": "image/svg+xml",
  ".json": "application/json; charset=utf-8",
  ".ico": "image/x-icon",
};

const runtime = createRuntime();

function send(res, code, body, headers = {}) {
  const payload = Buffer.isBuffer(body) ? body : Buffer.from(body);
  res.writeHead(code, { "Cache-Control": "no-store", "Content-Length": payload.length, ...headers });
  res.end(payload);
}

function json(res, code, value) {
  send(res, code, JSON.stringify(value), { "Content-Type": "application/json; charset=utf-8" });
}

function readBody(req, limit = 12 * 1024 * 1024) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on("data", (chunk) => {
      size += chunk.length;
      if (size > limit) {
        reject(Object.assign(new Error("Слишком большой запрос"), { status: 413 }));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => {
      if (!chunks.length) return resolve({});
      try { resolve(JSON.parse(Buffer.concat(chunks).toString("utf8"))); }
      catch { reject(Object.assign(new Error("Некорректный JSON"), { status: 400 })); }
    });
    req.on("error", reject);
  });
}

function cookieToken(req) {
  const raw = req.headers.cookie || "";
  const hit = raw.split(";").map((p) => p.trim()).find((p) => p.startsWith("alfa_session="));
  return hit ? decodeURIComponent(hit.slice("alfa_session=".length)) : "";
}

function setCookie(res, token) {
  const value = token
    ? `alfa_session=${encodeURIComponent(token)}; HttpOnly; SameSite=Lax; Path=/; Max-Age=1209600`
    : "alfa_session=; HttpOnly; SameSite=Lax; Path=/; Max-Age=0";
  res.setHeader("Set-Cookie", value);
}

function guard(req, res) {
  const token = cookieToken(req);
  if (!runtime.sessionOk(token)) {
    json(res, 401, { authenticated: false });
    return null;
  }
  return token;
}

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url || "/", "http://127.0.0.1");
    if (req.method === "GET" && url.pathname === "/api/health") {
      json(res, 200, { ok: true, version: runtime.state.version, port: PANEL_PORT });
      return;
    }
    if (req.method === "GET" && url.pathname === "/api/session") {
      const token = cookieToken(req);
      json(res, 200, {
        authenticated: runtime.sessionOk(token),
        installerAccess: false,
        passwordSet: true,
      });
      return;
    }
    if (req.method === "POST" && url.pathname === "/api/login") {
      const body = await readBody(req, 64 * 1024);
      const token = runtime.login(body.password, body.pairCode);
      setCookie(res, token);
      json(res, 200, { authenticated: true, installerAccess: false, passwordSet: true });
      return;
    }
    if (req.method === "POST" && url.pathname === "/api/logout") {
      runtime.logout(cookieToken(req));
      setCookie(res, "");
      json(res, 200, { authenticated: false });
      return;
    }
    if (req.method === "GET" && url.pathname === "/api/events") {
      if (!guard(req, res)) return;
      res.writeHead(200, {
        "Content-Type": "text/event-stream",
        "Cache-Control": "no-cache",
        Connection: "keep-alive",
      });
      res.write(`data: ${JSON.stringify({ type: "snapshot", state: runtime.snapshot() })}\n\n`);
      runtime.live.sse.add(res);
      req.on("close", () => runtime.live.sse.delete(res));
      return;
    }
    if (url.pathname === "/api/snapshot" && req.method === "GET") {
      if (!guard(req, res)) return;
      json(res, 200, runtime.snapshot());
      return;
    }
    const invoke = url.pathname.match(/^\/api\/invoke\/([a-zA-Z0-9_-]+)$/);
    if (invoke && req.method === "POST") {
      if (!guard(req, res)) return;
      const body = await readBody(req);
      const result = await runtime.invoke(invoke[1], body);
      json(res, 200, { ok: true, result });
      return;
    }
    if (req.method === "GET") {
      const rel = url.pathname === "/" ? "/index.html" : url.pathname;
      const file = normalize(join(PUBLIC, rel));
      if (!file.startsWith(PUBLIC + sep) && file !== PUBLIC || !existsSync(file)) {
        send(res, 404, "not found", { "Content-Type": "text/plain" });
        return;
      }
      send(res, 200, readFileSync(file), { "Content-Type": TYPES[extname(file)] || "application/octet-stream" });
      return;
    }
    send(res, 404, "not found", { "Content-Type": "text/plain" });
  } catch (error) {
    const status = error.status || 500;
    json(res, status, { ok: false, error: error.message || "Ошибка" });
  }
});

export function start(port = PANEL_PORT, host = "0.0.0.0") {
  return new Promise((resolve) => {
    server.listen(port, host, async () => {
      await runtime.boot();
      resolve(server);
    });
  });
}

export async function stop() {
  await runtime.shutdown();
  await new Promise((resolve) => server.close(resolve));
}

const isMain = process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;
if (isMain) {
  start().then(() => {
    console.log(`StealthSurf alfa http://0.0.0.0:${PANEL_PORT}`);
  });
}
