import { test } from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import { evaluate } from "../lib/policy.mjs";
import { defaultState } from "../lib/state.mjs";
import { writeConfigs, buildXray, buildSingBox, buildMihomo } from "../lib/engines.mjs";
import { parseShareLink, parseSubscriptionBody } from "../lib/subscription.mjs";

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
});

test("panel login, connect, proxy and explain", async () => {
  const { start, stop } = await import("../server.mjs");
  const origin = await start(8788, "127.0.0.1");
  assert.ok(origin);
  const local = http.createServer((req, res) => res.end("alfa-ok"));
  await new Promise((resolve) => local.listen(0, "127.0.0.1", resolve));
  const localPort = local.address().port;
  try {
    const bad = await fetch("http://127.0.0.1:8788/api/login", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ password: "nope" }) });
    assert.equal(bad.status, 401);
    const good = await fetch("http://127.0.0.1:8788/api/login", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ password: "alfa" }) });
    assert.equal(good.status, 200);
    const cookie = good.headers.getSetCookie?.()[0] || good.headers.get("set-cookie");
    const token = /alfa_session=([^;]+)/.exec(cookie)[1];
    const headers = { "Content-Type": "application/json", Cookie: `alfa_session=${token}` };
    const session = await fetch("http://127.0.0.1:8788/api/session", { headers });
    assert.equal((await session.json()).authenticated, true);
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
