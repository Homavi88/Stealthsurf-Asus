import { test } from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import net from "node:net";
import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { evaluate } from "../lib/policy.mjs";
import {
  assertPatch,
  checkPassword,
  defaultState,
  hashPassword,
  passwordNeedsUpgrade,
  setPath,
  ROOT,
  DATA,
} from "../lib/state.mjs";
import { readFileSync } from "node:fs";
import { scryptSync, randomBytes } from "node:crypto";
import { deflateRawSync } from "node:zlib";
import { buildMihomo, buildSingBox, buildXray, corePath, extractZipMember, writeConfigs } from "../lib/engines.mjs";
import { parseShareLink, parseSubscriptionBody } from "../lib/subscription.mjs";
import { dialTarget, startEdge } from "../lib/proxy.mjs";

test("password hash uses pbkdf2 and trims", () => {
  const stored = hashPassword("alfa");
  assert.equal(stored.algo, "pbkdf2-sha256");
  assert.equal(checkPassword("alfa", stored), true);
  assert.equal(checkPassword("  alfa  ", stored), true);
  assert.equal(checkPassword("alfa ", stored), true);
  assert.equal(checkPassword("wrong", stored), false);
  assert.equal(passwordNeedsUpgrade(stored), false);
});

test("legacy scrypt hashes still verify and need upgrade", () => {
  const salt = randomBytes(16).toString("hex");
  const hash = scryptSync("alfa", salt, 32, { N: 16384, r: 8, p: 1, maxmem: 64 * 1024 * 1024 }).toString("hex");
  const legacy = { salt, hash };
  assert.equal(checkPassword("alfa", legacy), true);
  assert.equal(passwordNeedsUpgrade(legacy), true);
  assert.equal(checkPassword("nope", legacy), false);
});

test("extractZipMember reads stored and deflated members without unzip", () => {
  const payload = Buffer.from("stealthsurf-core-bin");
  const stored = (() => {
    const name = Buffer.from("xray");
    const header = Buffer.alloc(30);
    header.writeUInt32LE(0x04034b50, 0);
    header.writeUInt16LE(20, 4);
    header.writeUInt16LE(0, 6);
    header.writeUInt16LE(0, 8); // store
    header.writeUInt32LE(payload.length, 18);
    header.writeUInt32LE(payload.length, 22);
    header.writeUInt16LE(name.length, 26);
    header.writeUInt16LE(0, 28);
    return Buffer.concat([header, name, payload]);
  })();
  assert.equal(extractZipMember(stored, "xray").toString(), "stealthsurf-core-bin");
  const deflated = deflateRawSync(payload);
  const zipDef = (() => {
    const name = Buffer.from("xray");
    const header = Buffer.alloc(30);
    header.writeUInt32LE(0x04034b50, 0);
    header.writeUInt16LE(20, 4);
    header.writeUInt16LE(0, 6);
    header.writeUInt16LE(8, 8); // deflate
    header.writeUInt32LE(deflated.length, 18);
    header.writeUInt32LE(payload.length, 22);
    header.writeUInt16LE(name.length, 26);
    header.writeUInt16LE(0, 28);
    return Buffer.concat([header, name, deflated]);
  })();
  assert.equal(extractZipMember(zipDef, "xray").toString(), "stealthsurf-core-bin");
});

test("UI select uses data-input and cell CSS avoids full-width crush", () => {
  const js = readFileSync(join(ROOT, "public/app.js"), "utf8");
  assert.match(js, /function sel\(/);
  assert.match(js, /data-input="\$\{esc\(path\)\}"/);
  assert.match(js, /navRow\(/);
  assert.match(js, /function fieldBlock\(/);
  assert.match(js, /busyCore/);
  const css = readFileSync(join(ROOT, "public/app.css"), "utf8");
  assert.match(css, /\.cell select\.ctrl/);
  assert.match(css, /max-width:\s*min\(52%/);
  assert.match(css, /\.cell input\.text/);
  assert.match(css, /\.switch\s*\{[\s\S]*?width:\s*46px\s*!important/);
  assert.match(css, /:root\[data-theme="light"\]/);
  assert.match(css, /--input:/);
  assert.match(css, /\.field-block/);
});

test("ROOT works on Node 18 without import.meta.dirname", () => {
  assert.equal(typeof ROOT, "string");
  assert.equal(typeof DATA, "string");
  assert.ok(ROOT.length > 0);
  assert.ok(existsSync(join(ROOT, "server.mjs")));
  assert.ok(existsSync(join(ROOT, "lib/state.mjs")));
  const src = readFileSync(join(ROOT, "lib/state.mjs"), "utf8");
  assert.match(src, /fileURLToPath\(import\.meta\.url\)/);
  assert.doesNotMatch(src, /join\(import\.meta\.dirname/);
});

test("policy sends telegram direct, ads blocked, exceptions direct", () => {
  const state = defaultState();
  state.vpn.connected = true;
  const at = (host, extra = {}) => evaluate(state, { host, port: 443, network: "tcp", clientIp: "192.168.50.44", ...extra });
  assert.equal(at("web.telegram.org").action, "direct");
  assert.equal(at("ads.example.test").action, "block");
  assert.equal(at("example.com").action, "proxy");
  assert.equal(at("example.com", { clientIp: "192.168.50.51" }).action, "direct");
  state.router.blockQuic = true;
  assert.equal(evaluate(state, { host: "example.com", port: 443, network: "udp", clientIp: "192.168.50.44" }).action, "block");
  state.router.blockWithoutVpn = true;
  state.vpn.connected = false;
  assert.equal(at("example.com").action, "block");
});

test("subscription links and all four engine configs build", () => {
  const state = defaultState();
  const node = parseShareLink("vless://11111111-1111-1111-1111-111111111111@example.com:443?security=tls&type=ws&path=%2Fv#NL");
  assert.equal(node.protocol, "vless");
  assert.equal(node.transport, "ws");
  const body = Buffer.from("trojan://secret@example.com:443#T\n", "utf8").toString("base64");
  assert.equal(parseSubscriptionBody(body).length, 1);
  state.vpn.connected = true;
  const xray = buildXray(state, node);
  assert.equal(xray.outbounds[0].protocol, "vless");
  assert.ok(xray.routing.rules.some((rule) => rule.outboundTag === "direct"));
  const sing = buildSingBox(state, node);
  assert.equal(sing.outbounds[0].type, "vless");
  const yaml = buildMihomo(state, node);
  assert.match(yaml, /type: vless/);
  assert.match(yaml, /DOMAIN-SUFFIX,telegram.org,DIRECT/);
  const hysteria = { ...node, protocol: "hysteria2", name: "hy" };
  const written = writeConfigs({ ...state, engine: { ...state.engine, preference: "auto" } }, hysteria);
  assert.equal(written.choice.id, "sing-box");
  const mihomo = writeConfigs({ ...state, engine: { ...state.engine, preference: "auto" } }, { ...node, protocol: "amneziawg", privateKey: "a", peerKey: "b", host: "1.2.3.4", port: 51820 });
  assert.equal(mihomo.choice.id, "mihomo");
  const again = parseShareLink("vless://11111111-1111-1111-1111-111111111111@example.com:443?security=tls&type=ws&path=%2Fv#NL");
  assert.equal(again.id, node.id);
  const foreign = { ...node, protocol: "hysteria2", alpha: false };
  assert.equal(buildXray(state, foreign).outbounds[0].protocol, "blackhole");
  const wg = buildSingBox(state, { ...node, protocol: "wireguard", privateKey: "a", peerKey: "b", host: "1.2.3.4", port: 51820 });
  assert.equal(wg.endpoints[0].type, "wireguard");
  assert.equal(wg.outbounds.some((item) => item.type === "block"), false);
  assert.equal(buildSingBox(state, node).outbounds.some((item) => item.type === "block"), false);
  const shared = buildMihomo({ ...state, connection: { ...state.connection, shareLan: true } }, node);
  assert.match(shared, /bind-address: '\*'/);
  assert.throws(() => assertPatch("vpn"), /конкретное поле/);
  assert.throws(() => setPath({}, "router.__proto__.polluted", 1), /Недопустимый путь/);
  const ctx = { live: { fakeToHost: new Map([["198.18.0.8", "example.com"]]) } };
  assert.equal(dialTarget(ctx, "198.18.0.8"), "example.com");
  assert.equal(buildSingBox(state, { ...node, protocol: "socks", host: "10.0.0.1", port: 1080 }).outbounds[0].type, "socks");
  assert.equal(buildSingBox(state, { ...node, protocol: "http", host: "10.0.0.1", port: 8080 }).outbounds[0].type, "http");
  const rejected = buildSingBox(state, { ...node, protocol: "amneziawg" });
  assert.ok(rejected.route.rules.length > 0);
  assert.ok(rejected.route.rules.every((rule) => rule.network));
});

test("edge keeps socks and http on different ports", async () => {
  const hold = net.createServer();
  await new Promise((resolve) => hold.listen(20808, "127.0.0.1", resolve));
  const state = defaultState();
  state.engine.socksPort = 20808;
  state.engine.httpPort = 20809;
  const edge = await startEdge({ state, live: { tunnel: "off", fakeToHost: new Map() }, hooks: {} });
  try {
    assert.notEqual(edge.socksPort, edge.httpPort);
    assert.notEqual(edge.socksPort, 20808);
  } finally {
    edge.stop();
    await new Promise((resolve) => hold.close(resolve));
  }
});

test("installed cores accept the 1.14 configs", () => {
  const state = defaultState();
  state.vpn.connected = true;
  const node = parseShareLink("vless://11111111-1111-1111-1111-111111111111@example.com:443?security=tls&type=ws#NL");
  const dir = mkdtempSync(join(tmpdir(), "alfa-"));
  const singBin = corePath("sing-box");
  if (singBin && existsSync(singBin)) {
    const file = join(dir, "sing.json");
    const wg = buildSingBox(state, { ...node, protocol: "wireguard", privateKey: "YIZq1Z3aW0f2m5q0n1p2r3s4t5u6v7w8x9y0z1A2B3C=", peerKey: "YIZq1Z3aW0f2m5q0n1p2r3s4t5u6v7w8x9y0z1A2B3D=", host: "1.2.3.4", port: 51820 });
    writeFileSync(file, JSON.stringify(wg));
    const checked = spawnSync(singBin, ["check", "-c", file], { encoding: "utf8" });
    assert.equal(checked.status, 0, checked.stderr || checked.stdout);
    const plain = join(dir, "sing-vless.json");
    writeFileSync(plain, JSON.stringify(buildSingBox(state, node)));
    const plainCheck = spawnSync(singBin, ["check", "-c", plain], { encoding: "utf8" });
    assert.equal(plainCheck.status, 0, plainCheck.stderr || plainCheck.stdout);
    const socksFile = join(dir, "sing-socks.json");
    writeFileSync(socksFile, JSON.stringify(buildSingBox(state, { ...node, protocol: "socks", host: "10.0.0.1", port: 1080 })));
    const socksCheck = spawnSync(singBin, ["check", "-c", socksFile], { encoding: "utf8" });
    assert.equal(socksCheck.status, 0, socksCheck.stderr || socksCheck.stdout);
    const rejectFile = join(dir, "sing-reject.json");
    writeFileSync(rejectFile, JSON.stringify(buildSingBox(state, { ...node, protocol: "amneziawg" })));
    const rejectCheck = spawnSync(singBin, ["check", "-c", rejectFile], { encoding: "utf8" });
    assert.equal(rejectCheck.status, 0, rejectCheck.stderr || rejectCheck.stdout);
  }
  const mihomoBin = corePath("mihomo");
  if (mihomoBin && existsSync(mihomoBin)) {
    const file = join(dir, "mihomo.yaml");
    writeFileSync(file, buildMihomo({ ...state, connection: { ...state.connection, shareLan: true } }, node));
    const checked = spawnSync(mihomoBin, ["-t", "-f", file], { encoding: "utf8" });
    assert.equal(checked.status, 0, checked.stderr || checked.stdout);
  }
});

test("plain http proxy forwards a split body and ignores the next request", async () => {
  const local = http.createServer((req, res) => {
    const chunks = [];
    req.on("data", (chunk) => chunks.push(chunk));
    req.on("end", () => res.end(Buffer.concat(chunks)));
  });
  await new Promise((resolve) => local.listen(0, "127.0.0.1", resolve));
  const state = defaultState();
  state.vpn.connected = true;
  state.engine.socksPort = 20980;
  state.engine.httpPort = 20981;
  const edge = await startEdge({ state, live: { tunnel: "off", fakeToHost: new Map() }, hooks: {} });
  const port = local.address().port;
  try {
    const posted = await rawProxy(edge.httpPort, (socket) => {
      const body = "hello-alfa-body";
      socket.write(`POST http://127.0.0.1:${port}/x HTTP/1.1\r\nHost: 127.0.0.1:${port}\r\nContent-Length: ${body.length}\r\n\r\n`);
      socket.write(body.slice(0, 5));
      setTimeout(() => socket.write(body.slice(5) + "GET /second HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"), 40);
    });
    assert.match(posted, /hello-alfa-body/);
    assert.doesNotMatch(posted, /GET \/second/);
    const chunked = await rawProxy(edge.httpPort, (socket) => {
      socket.write(`POST http://127.0.0.1:${port}/c HTTP/1.1\r\nHost: 127.0.0.1:${port}\r\nTransfer-Encoding: chunked\r\n\r\n`);
      socket.write("5\r\nhello\r\n");
      setTimeout(() => socket.write("5\r\n-alfa\r\n0\r\n\r\nGET /second HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"), 40);
    });
    assert.match(chunked, /hello-alfa/);
    assert.doesNotMatch(chunked, /GET \/second/);
  } finally {
    edge.stop();
    await new Promise((resolve) => local.close(resolve));
  }
});

test("panel opens without password, connect, proxy and explain", async () => {
  const { start, stop } = await import("../server.mjs");
  const origin = await start(8788, "127.0.0.1");
  assert.ok(origin);
  const local = http.createServer((req, res) => res.end("alfa-ok"));
  await new Promise((resolve) => local.listen(0, "127.0.0.1", resolve));
  const localPort = local.address().port;
  try {
    const health = await fetch("http://127.0.0.1:8788/api/health");
    assert.equal(health.status, 200);
    assert.equal((await health.json()).openAccess, true);
    const session = await fetch("http://127.0.0.1:8788/api/session");
    assert.equal(session.status, 200);
    const sessionBody = await session.json();
    assert.equal(sessionBody.authenticated, true);
    assert.equal(sessionBody.openAccess, true);
    const cookie = session.headers.getSetCookie?.()[0] || session.headers.get("set-cookie");
    assert.match(cookie || "", /alfa_session=/);
    const token = /alfa_session=([^;]+)/.exec(cookie)[1];
    const headers = { "Content-Type": "application/json", Cookie: `alfa_session=${token}` };
    // повторный session с cookie тоже ок
    const again = await fetch("http://127.0.0.1:8788/api/session", { headers });
    assert.equal((await again.json()).authenticated, true);
    const page = await fetch("http://127.0.0.1:8788/");
    assert.match(await page.text(), /StealthSurf VPN/);
    const connected = await fetch("http://127.0.0.1:8788/api/invoke/connect", { method: "POST", headers, body: "{}" });
    const connectedBody = await connected.json();
    assert.equal(connectedBody.ok, true, connectedBody.error);
    assert.ok(["alpha-direct", "engine"].includes(connectedBody.result.tunnel), connectedBody.result.message);
    const snap = await (await fetch("http://127.0.0.1:8788/api/snapshot", { headers })).json();
    const explained = await fetch("http://127.0.0.1:8788/api/invoke/explain", {
      method: "POST",
      headers,
      body: JSON.stringify({ host: "ads.example.test", clientIp: "192.168.50.44" }),
    });
    assert.equal((await explained.json()).result.action, "block");
    const blocked = await fetch("http://ads.example.test/", { dispatcher: undefined, headers: {} }).catch(() => null);
    void blocked;
    const proxyPort = snap.runtime.httpPort;
    const ad = await proxyRequest(proxyPort, "ads.example.test", 80, "/");
    assert.match(ad, /403/);
    const ok = await proxyRequest(proxyPort, "127.0.0.1", localPort, "/");
    assert.match(ok, /alfa-ok/);
    const tg = await (await fetch("http://127.0.0.1:8788/api/invoke/explain", {
      method: "POST",
      headers,
      body: JSON.stringify({ host: "telegram.org" }),
    })).json();
    assert.equal(tg.result.action, "direct");
  } finally {
    local.close();
    await stop();
  }
});

function rawProxy(port, write) {
  return new Promise((resolve, reject) => {
    const socket = net.connect(port, "127.0.0.1", () => write(socket));
    let data = "";
    socket.on("data", (chunk) => { data += chunk; });
    socket.on("end", () => resolve(data));
    socket.on("error", reject);
    setTimeout(() => { socket.destroy(); resolve(data); }, 2000);
  });
}

function proxyRequest(port, host, targetPort, path) {
  return new Promise((resolve, reject) => {
    const req = http.request({
      host: "127.0.0.1",
      port,
      method: "GET",
      path: `http://${host}:${targetPort}${path}`,
      headers: { Host: `${host}:${targetPort}` },
      timeout: 4000,
    });
    req.on("response", (res) => {
      let data = `HTTP ${res.statusCode}\n`;
      res.on("data", (c) => { data += c; });
      res.on("end", () => resolve(data));
    });
    req.on("error", reject);
    req.end();
  });
}
