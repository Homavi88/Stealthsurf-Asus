import { spawn } from "node:child_process";
import { mkdirSync, writeFileSync, existsSync, rmSync, statSync, createWriteStream, createReadStream } from "node:fs";
import { join } from "node:path";
import { createGunzip } from "node:zlib";
import { pipeline } from "node:stream/promises";
import { Readable } from "node:stream";
import { execFile as execFileCb } from "node:child_process";
import { promisify } from "node:util";

const execFile = promisify(execFileCb);
import { DATA } from "./state.mjs";
import { ENGINES, pickEngine } from "./catalog.mjs";
import { dnsServers, ruleList } from "./policy.mjs";

export const RUN_DIR = join(DATA, "run");
export const CORE_DIR = join(DATA, "cores");
export const GEO_DIR = join(DATA, "geo");
export const ENGINE_PORT = 20828;

export function chosenEngine(state, node) {
  const preference = state.engine.preference || "auto";
  const protocol = node?.protocol || "direct";
  const id = pickEngine(preference, protocol);
  return { id, meta: ENGINES[id], preference };
}

function domainStrategy(state) {
  if (state.engine.domainStrategy && state.engine.domainStrategy !== "auto") return state.engine.domainStrategy;
  if (state.engine.fakeIp) return "IPIfNonMatch";
  return "AsIs";
}

function xrayAction(action) {
  if (action === "block") return "block";
  if (action === "direct") return "direct";
  return "proxy";
}

function xrayRule(rule) {
  const out = { type: "field", outboundTag: xrayAction(rule.action) };
  const match = rule.match || {};
  if (match.port) out.port = String(match.port);
  if (match.network === "udp") out.network = "udp";
  if (match.suffixes?.length) out.domain = match.suffixes.map((s) => `domain:${s}`);
  if (match.ru) out.domain = ["regexp:(^|\\.)ru$", "regexp:(^|\\.)su$", "regexp:(^|\\.)xn--p1ai$"];
  if (match.cidrs?.length) out.ip = match.cidrs.filter((c) => !c.includes(":"));
  if (match.ports) out.port = match.ports.map(([a, b]) => (a === b ? String(a) : `${a}-${b}`)).join(",");
  if (match.clientIps?.length) out.source = match.clientIps;
  if (match.custom) {
    const domains = [];
    const ips = [];
    for (const cond of match.custom.conditions || []) {
      if (cond.kind === "domain") domains.push(cond.value.startsWith("domain:") ? cond.value : `domain:${cond.value}`);
      if (cond.kind === "geosite") domains.push(`geosite:${cond.value}`);
      if (cond.kind === "ip" || cond.kind === "cidr") ips.push(cond.value);
      if (cond.kind === "geoip") ips.push(`geoip:${cond.value}`);
      if (cond.kind === "port") out.port = String(cond.value);
      if (cond.kind === "protocol" && cond.value === "bittorrent") out.protocol = ["bittorrent"];
    }
    if (domains.length) out.domain = domains;
    if (ips.length) out.ip = ips;
  }
  if (match.configRule) {
    const domains = [];
    const ips = [];
    for (const item of match.configRule.domains || []) domains.push(item);
    for (const item of match.configRule.ips || []) ips.push(item);
    if (domains.length) out.domain = domains;
    if (ips.length) out.ip = ips;
    if (match.configRule.protocol === "bittorrent") out.protocol = ["bittorrent"];
  }
  if (!out.domain && !out.ip && !out.port && !out.source && !out.protocol && !out.network) return null;
  return out;
}

function streamSettings(node, state) {
  if (!node || node.alpha || node.protocol === "direct") return undefined;
  const network = node.transport || "tcp";
  const security = node.security || (node.protocol === "trojan" ? "tls" : "none");
  const stream = { network };
  if (network === "ws") stream.wsSettings = { path: node.path || "/", headers: node.hostHeader ? { Host: node.hostHeader } : undefined };
  if (network === "grpc") stream.grpcSettings = { serviceName: node.serviceName || "" };
  if (network === "xhttp" || network === "splithttp") {
    stream.network = "xhttp";
    stream.xhttpSettings = { path: node.path || "/", host: node.hostHeader || node.sni || "" };
  }
  if (security === "tls") {
    stream.security = "tls";
    stream.tlsSettings = {
      serverName: node.sni || node.host,
      fingerprint: node.fingerprint || "chrome",
      alpn: node.alpn ? node.alpn.split(",") : undefined,
    };
  } else if (security === "reality") {
    stream.security = "reality";
    stream.realitySettings = {
      serverName: node.sni || node.host,
      fingerprint: node.fingerprint || "chrome",
      publicKey: node.publicKey || "",
      shortId: node.shortId || "",
    };
  }
  if (state.routing.fragment) {
    stream.sockopt = { ...(stream.sockopt || {}), dialerProxy: "fragment" };
  }
  const bridge = (state.connection.bridges || []).find((item) => item.from === node.id);
  if (bridge?.to) stream.sockopt = { ...(stream.sockopt || {}), dialerProxy: `bridge-${bridge.to}` };
  return stream;
}

function xrayOutbound(node, state) {
  if (!node || node.protocol === "direct" || node.alpha) {
    return { tag: "proxy", protocol: "freedom", settings: state.connection.ipv4Only ? { domainStrategy: "UseIPv4" } : {} };
  }
  const muxOn = state.connection.mux === "custom" || (state.connection.mux === "subscription" && node.mux);
  const mux = muxOn ? { enabled: true, concurrency: Number(state.connection.muxConcurrency || 8) } : { enabled: false };
  const stream = streamSettings(node, state);
  if (node.protocol === "vless") {
    return {
      tag: "proxy",
      protocol: "vless",
      settings: { vnext: [{ address: node.host, port: Number(node.port), users: [{ id: node.uuid, encryption: "none", flow: node.flow || "" }] }] },
      streamSettings: stream,
      mux,
    };
  }
  if (node.protocol === "vmess") {
    return {
      tag: "proxy",
      protocol: "vmess",
      settings: { vnext: [{ address: node.host, port: Number(node.port), users: [{ id: node.uuid, alterId: node.alterId || 0, security: "auto" }] }] },
      streamSettings: stream,
      mux,
    };
  }
  if (node.protocol === "trojan") {
    return {
      tag: "proxy",
      protocol: "trojan",
      settings: { servers: [{ address: node.host, port: Number(node.port), password: node.password || "" }] },
      streamSettings: stream,
      mux,
    };
  }
  if (node.protocol === "shadowsocks") {
    return {
      tag: "proxy",
      protocol: "shadowsocks",
      settings: { servers: [{ address: node.host, port: Number(node.port), method: node.method || "aes-128-gcm", password: node.password || "" }] },
      mux,
    };
  }
  if (node.protocol === "socks" || node.protocol === "http") {
    return {
      tag: "proxy",
      protocol: node.protocol,
      settings: { servers: [{ address: node.host, port: Number(node.port) }] },
    };
  }
  return { tag: "proxy", protocol: "blackhole", settings: {} };
}

function warpOutbound(state) {
  const profile = state.connection.warpProfile;
  if (!profile || state.connection.warpMode === "off") return null;
  return {
    tag: "warp",
    protocol: "wireguard",
    settings: {
      secretKey: profile.privateKey,
      address: [profile.address || "172.16.0.2/32"],
      peers: [{ publicKey: profile.peerKey, endpoint: `${profile.host}:${profile.port}` }],
      mtu: profile.mtu || 1280,
    },
  };
}

export function buildXray(state, node, { tunnelOnly = false } = {}) {
  const listen = state.connection.shareLan ? "0.0.0.0" : "127.0.0.1";
  const socksPort = tunnelOnly ? ENGINE_PORT : Number(state.engine.socksPort || 20808);
  const httpPort = Number(state.engine.httpPort || 20809);
  const dns = dnsServers(state);
  const inbounds = [
    {
      tag: "socks-in",
      listen,
      port: socksPort,
      protocol: "socks",
      settings: { udp: true, auth: "noauth" },
      sniffing: { enabled: true, destOverride: ["http", "tls", "quic"] },
    },
  ];
  if (!tunnelOnly) {
    inbounds.push({
      tag: "http-in",
      listen,
      port: httpPort,
      protocol: "http",
      settings: {},
      sniffing: { enabled: true, destOverride: ["http", "tls"] },
    });
  }
  const outbounds = [
    xrayOutbound(node, state),
    { tag: "direct", protocol: "freedom", settings: state.connection.ipv4Only ? { domainStrategy: "UseIPv4" } : {} },
    { tag: "block", protocol: "blackhole", settings: {} },
  ];
  if (state.routing.fragment) {
    outbounds.push({
      tag: "fragment",
      protocol: "freedom",
      settings: { fragment: { packets: "tlshello", length: "100-200", interval: "10-20" } },
    });
  }
  const warp = warpOutbound(state);
  if (warp) outbounds.push(warp);
  for (const bridge of state.connection.bridges || []) {
    const target = state.subscriptions.flatMap((s) => s.nodes).find((n) => n.id === bridge.to);
    if (!target) continue;
    const outbound = xrayOutbound(target, { ...state, routing: { ...state.routing, fragment: false }, connection: { ...state.connection, bridges: [] } });
    outbound.tag = `bridge-${target.id}`;
    outbounds.push(outbound);
  }
  const rules = tunnelOnly ? [] : ruleList(state).map(xrayRule).filter(Boolean);
  if (state.engine.fakeIp && !tunnelOnly) {
    rules.unshift({ type: "field", ip: ["198.18.0.0/15"], outboundTag: "proxy" });
  }
  const config = {
    log: { loglevel: state.diagnostics.logLevel || "warning" },
    dns: {
      servers: state.engine.fakeIp ? ["fakedns", ...dns.primary] : dns.primary,
      queryStrategy: state.connection.ipv4Only ? "UseIPv4" : "UseIP",
    },
    fakedns: state.engine.fakeIp ? [{ ipPool: "198.18.0.0/15", poolSize: 65535 }] : undefined,
    inbounds,
    outbounds,
    routing: {
      domainStrategy: domainStrategy(state),
      rules,
    },
  };
  return config;
}

function singPlan(node) {
  if (!node || node.alpha || node.protocol === "direct") return { outbound: { type: "direct", tag: "proxy" } };
  const base = { tag: "proxy", server: node.host, server_port: Number(node.port) };
  if (node.protocol === "vless") {
    return { outbound: { ...base, type: "vless", uuid: node.uuid || "", flow: node.flow || undefined, tls: tlsBlock(node), transport: transportBlock(node) } };
  }
  if (node.protocol === "trojan") return { outbound: { ...base, type: "trojan", password: node.password || "", tls: tlsBlock(node) } };
  if (node.protocol === "vmess") return { outbound: { ...base, type: "vmess", uuid: node.uuid || "", security: "auto", alter_id: node.alterId || 0, tls: tlsBlock(node), transport: transportBlock(node) } };
  if (node.protocol === "shadowsocks") return { outbound: { ...base, type: "shadowsocks", method: node.method || "aes-128-gcm", password: node.password || "" } };
  if (node.protocol === "hysteria2") return { outbound: { ...base, type: "hysteria2", password: node.password || "", tls: { enabled: true, server_name: node.sni || node.host, insecure: Boolean(node.insecure) } } };
  if (node.protocol === "tuic") return { outbound: { ...base, type: "tuic", uuid: node.uuid || "", password: node.password || "", congestion_control: node.congestion || "bbr", tls: { enabled: true, server_name: node.sni || node.host } } };
  if (node.protocol === "wireguard") {
    return {
      endpoint: {
        type: "wireguard",
        tag: "proxy",
        system: false,
        mtu: node.mtu || 1280,
        address: [node.address || "10.0.0.2/32"],
        private_key: node.privateKey || "",
        peers: [{
          address: node.host,
          port: Number(node.port),
          public_key: node.peerKey || "",
          allowed_ips: ["0.0.0.0/0", "::/0"],
        }],
      },
    };
  }
  return { reject: true };
}

function tlsBlock(node) {
  if (node.security !== "tls" && node.security !== "reality" && node.protocol !== "trojan") return undefined;
  return {
    enabled: true,
    server_name: node.sni || node.host,
    utls: node.fingerprint ? { enabled: true, fingerprint: node.fingerprint } : undefined,
    reality: node.security === "reality" ? { enabled: true, public_key: node.publicKey || "", short_id: node.shortId || "" } : undefined,
  };
}

function transportBlock(node) {
  const type = node.transport || "tcp";
  if (type === "tcp") return undefined;
  if (type === "ws") return { type: "ws", path: node.path || "/" };
  if (type === "grpc") return { type: "grpc", service_name: node.serviceName || "" };
  if (type === "xhttp" || type === "splithttp") return { type: "xhttp", path: node.path || "/" };
  return { type };
}

function singRule(rule) {
  const match = rule.match || {};
  const out = rule.action === "block"
    ? { action: "reject" }
    : { action: "route", outbound: xrayAction(rule.action) };
  if (match.suffixes?.length) out.domain_suffix = match.suffixes;
  if (match.ru) out.domain_suffix = ["ru", "su", "xn--p1ai"];
  if (match.cidrs?.length) out.ip_cidr = match.cidrs;
  if (match.port) out.port = [Number(match.port)];
  if (match.network === "udp") out.network = "udp";
  if (match.ports) out.port_range = match.ports.map(([a, b]) => `${a}:${b}`);
  if (match.clientIps?.length) out.source_ip_cidr = match.clientIps.map((ip) => (ip.includes("/") ? ip : `${ip}/32`));
  if (!out.domain_suffix && !out.ip_cidr && !out.port && !out.network && !out.port_range && !out.source_ip_cidr) return null;
  return out;
}

export function buildSingBox(state, node, { tunnelOnly = false } = {}) {
  const listen = state.connection.shareLan ? "0.0.0.0" : "127.0.0.1";
  const port = tunnelOnly ? ENGINE_PORT : Number(state.engine.socksPort || 20808);
  const plan = singPlan(node);
  const rules = tunnelOnly || plan.reject ? [] : ruleList(state).map(singRule).filter(Boolean);
  if (plan.reject) rules.push({ action: "reject" });
  const dns = dnsServers(state);
  const dnsServersList = [{ type: "udp", tag: "remote", server: dns.primary[0] }];
  if (state.engine.fakeIp && !tunnelOnly) {
    dnsServersList.unshift({ type: "fakeip", tag: "fakeip", inet4_range: "198.18.0.0/15" });
  }
  const outbounds = [{ type: "direct", tag: "direct" }];
  if (plan.outbound) outbounds.unshift(plan.outbound);
  const config = {
    log: { level: state.diagnostics.logLevel === "debug" ? "debug" : "warn" },
    dns: {
      servers: dnsServersList,
      strategy: state.connection.ipv4Only ? "ipv4_only" : "prefer_ipv4",
      final: "remote",
    },
    inbounds: [{ type: tunnelOnly ? "socks" : "mixed", tag: "in", listen, listen_port: port }],
    outbounds,
    route: { rules, final: plan.endpoint || plan.outbound ? "proxy" : "direct", auto_detect_interface: true },
  };
  if (plan.endpoint) config.endpoints = [plan.endpoint];
  return config;
}

function yamlQuote(value) {
  return `'${String(value ?? "").replace(/'/g, "''")}'`;
}

function mihomoProxy(node) {
  if (!node || node.alpha || node.protocol === "direct") return null;
  const lines = [`  - name: ${yamlQuote(node.name || "proxy")}`, `    server: ${yamlQuote(node.host)}`, `    port: ${Number(node.port)}`];
  const map = {
    vless: "vless",
    vmess: "vmess",
    trojan: "trojan",
    shadowsocks: "ss",
    hysteria2: "hysteria2",
    tuic: "tuic",
    wireguard: "wireguard",
    amneziawg: "wireguard",
  };
  lines.splice(1, 0, `    type: ${map[node.protocol] || "socks"}`);
  if (node.uuid) lines.push(`    uuid: ${yamlQuote(node.uuid)}`);
  if (node.password) lines.push(`    password: ${yamlQuote(node.password)}`);
  if (node.method) lines.push(`    cipher: ${yamlQuote(node.method)}`);
  if (node.sni) lines.push(`    sni: ${yamlQuote(node.sni)}`);
  if (node.flow) lines.push(`    flow: ${yamlQuote(node.flow)}`);
  if (node.transport && node.transport !== "tcp") lines.push(`    network: ${yamlQuote(node.transport)}`);
  if (node.security === "tls" || node.protocol === "trojan" || node.protocol === "hysteria2") lines.push("    tls: true");
  if (node.publicKey) lines.push(`    reality-opts:`, `      public-key: ${yamlQuote(node.publicKey)}`, `      short-id: ${yamlQuote(node.shortId || "")}`);
  if (node.privateKey) lines.push(`    private-key: ${yamlQuote(node.privateKey)}`, `    ip: ${yamlQuote(node.address || "10.0.0.2/32")}`, `    public-key: ${yamlQuote(node.peerKey || "")}`);
  return lines.join("\n");
}

function mihomoRule(rule) {
  const action = rule.action === "proxy" ? "PROXY" : rule.action === "block" ? "REJECT" : "DIRECT";
  const match = rule.match || {};
  const lines = [];
  for (const suffix of match.suffixes || []) lines.push(`  - DOMAIN-SUFFIX,${suffix},${action}`);
  if (match.ru) ["ru", "su"].forEach((s) => lines.push(`  - DOMAIN-SUFFIX,${s},${action}`));
  for (const cidr of match.cidrs || []) lines.push(`  - IP-CIDR,${cidr},${action}`);
  if (match.port && match.network === "udp") lines.push(`  - AND,((NETWORK,UDP),(DST-PORT,${match.port})),${action}`);
  if (match.ports) lines.push(`  - DST-PORT,6881-6999,${action}`);
  return lines;
}

export function buildMihomo(state, node, { tunnelOnly = false } = {}) {
  const port = tunnelOnly ? ENGINE_PORT : Number(state.engine.socksPort || 20808);
  const dns = dnsServers(state);
  const proxy = mihomoProxy(node);
  const rules = tunnelOnly ? ["  - MATCH,PROXY"] : ruleList(state).flatMap(mihomoRule);
  rules.push("  - MATCH,PROXY");
  return [
    `mixed-port: ${port}`,
    `allow-lan: ${state.connection.shareLan ? "true" : "false"}`,
    `mode: rule`,
    `ipv6: ${state.connection.ipv4Only || state.router.ipv6 === "block" ? "false" : "true"}`,
    `bind-address: ${state.connection.shareLan ? "'*'" : "127.0.0.1"}`,
    state.engine.fakeIp && !tunnelOnly ? "fake-ip-range: 198.18.0.0/15" : "",
    "dns:",
    `  enable: true`,
    `  enhanced-mode: ${state.engine.fakeIp ? "fake-ip" : "redir-host"}`,
    "  nameserver:",
    ...dns.primary.map((ip) => `    - ${ip}`),
    "proxies:",
    proxy || "  []",
    "proxy-groups:",
    "  - name: PROXY",
    "    type: select",
    `    proxies: [${proxy ? yamlQuote(node.name || "proxy") : "DIRECT"}]`,
    "rules:",
    ...rules,
  ].filter(Boolean).join("\n") + "\n";
}

export function writeConfigs(state, node) {
  mkdirSync(RUN_DIR, { recursive: true });
  const choice = chosenEngine(state, node);
  const full = {
    xray: buildXray(state, node, { tunnelOnly: false }),
    ferrum: buildXray(state, node, { tunnelOnly: false }),
    "sing-box": buildSingBox(state, node, { tunnelOnly: false }),
  };
  const tunnel = {
    xray: buildXray(state, node, { tunnelOnly: true }),
    ferrum: buildXray(state, node, { tunnelOnly: true }),
    "sing-box": buildSingBox(state, node, { tunnelOnly: true }),
  };
  writeFileSync(join(RUN_DIR, "xray.full.json"), JSON.stringify(full.xray, null, 2));
  writeFileSync(join(RUN_DIR, "ferrum.full.json"), JSON.stringify({ ...full.ferrum, remarks: "Ferrum принимает тот же JSON, что Xray" }, null, 2));
  writeFileSync(join(RUN_DIR, "sing-box.full.json"), JSON.stringify(full["sing-box"], null, 2));
  writeFileSync(join(RUN_DIR, "mihomo.full.yaml"), buildMihomo(state, node, { tunnelOnly: false }));
  writeFileSync(join(RUN_DIR, "xray.tunnel.json"), JSON.stringify(tunnel.xray, null, 2));
  writeFileSync(join(RUN_DIR, "ferrum.tunnel.json"), JSON.stringify(tunnel.ferrum, null, 2));
  writeFileSync(join(RUN_DIR, "sing-box.tunnel.json"), JSON.stringify(tunnel["sing-box"], null, 2));
  writeFileSync(join(RUN_DIR, "mihomo.tunnel.yaml"), buildMihomo(state, node, { tunnelOnly: true }));
  const activeId = choice.id;
  const activePath = activeId === "mihomo"
    ? join(RUN_DIR, "mihomo.tunnel.yaml")
    : join(RUN_DIR, `${activeId}.tunnel.json`);
  return { choice, activePath, fullPath: activeId === "mihomo" ? join(RUN_DIR, "mihomo.full.yaml") : join(RUN_DIR, `${activeId}.full.json`) };
}

export function corePath(id) {
  const name = ENGINES[id]?.bin;
  if (!name) return null;
  return join(CORE_DIR, name);
}

export function coreStatus(state) {
  const out = {};
  for (const id of ["xray", "ferrum", "sing-box", "mihomo"]) {
    const file = corePath(id);
    const installed = file && existsSync(file);
    out[id] = {
      id,
      title: ENGINES[id].title,
      ref: ENGINES[id].ref,
      installed,
      bytes: installed ? statSync(file).size : 0,
      path: installed ? file : "",
      note: state.engine.cores?.[id]?.note || "",
      version: state.engine.cores?.[id]?.version || "",
    };
  }
  return out;
}

let engineChild = null;

export function engineRunning() {
  return Boolean(engineChild && engineChild.exitCode === null && !engineChild.killed);
}

export async function stopEngine() {
  const child = engineChild;
  engineChild = null;
  if (!child || child.exitCode !== null) return;
  try { child.kill("SIGTERM"); } catch { return; }
  await new Promise((resolve) => {
    const timer = setTimeout(() => { child.kill("SIGKILL"); resolve(); }, 1500);
    child.once("exit", () => { clearTimeout(timer); resolve(); });
  });
}

export function startEngine(id, configPath, onLog) {
  const bin = corePath(id);
  if (!bin || !existsSync(bin)) {
    return { started: false, reason: `${ENGINES[id].title} не установлен` };
  }
  const args = id === "mihomo"
    ? ["-f", configPath]
    : id === "sing-box"
      ? ["run", "-c", configPath]
      : ["run", "-c", configPath];
  const child = spawn(bin, args, { stdio: ["ignore", "pipe", "pipe"] });
  engineChild = child;
  const take = (buf) => {
    const text = buf.toString("utf8");
    for (const line of text.split(/\r?\n/)) {
      if (!line.trim()) continue;
      onLog?.(redact(line));
    }
  };
  child.stdout.on("data", take);
  child.stderr.on("data", take);
  child.on("error", (error) => {
    if (engineChild === child) engineChild = null;
    onLog?.(`ядро ${id} не запустилось: ${error.message}`);
  });
  child.on("exit", (code) => {
    if (engineChild === child) engineChild = null;
    onLog?.(`ядро ${id} завершилось с кодом ${code}`);
  });
  return { started: true, pid: child.pid };
}

function redact(line) {
  return line
    .replace(/(password|uuid|private-key|secretKey|public-key)(["']?\s*[:=]\s*["']?)([^"',\s}]+)/gi, "$1$2***")
    .slice(0, 500);
}

export async function waitForPort(port, host = "127.0.0.1", timeoutMs = 4000) {
  const net = await import("node:net");
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    const ok = await new Promise((resolve) => {
      const socket = net.connect({ port, host });
      const done = (value) => { socket.destroy(); resolve(value); };
      socket.once("connect", () => done(true));
      socket.once("error", () => done(false));
      socket.setTimeout(250, () => done(false));
    });
    if (ok) return true;
    await new Promise((r) => setTimeout(r, 120));
  }
  return false;
}

export async function testConfig(id) {
  const bin = corePath(id);
  if (!bin || !existsSync(bin)) return { ok: false, error: "ядро не скачано" };
  const file = id === "mihomo" ? join(RUN_DIR, "mihomo.full.yaml") : join(RUN_DIR, `${id}.full.json`);
  if (!existsSync(file)) return { ok: false, error: "конфиг ещё не собран" };
  const args = id === "mihomo" ? ["-t", "-f", file] : id === "sing-box" ? ["check", "-c", file] : ["run", "-test", "-c", file];
  const result = await runCapture(bin, args);
  return { ok: result.code === 0, code: result.code, output: redact(result.output).slice(0, 1200) };
}

function runCapture(bin, args, timeoutMs = 5000) {
  return new Promise((resolve) => {
    const child = spawn(bin, args, { stdio: ["ignore", "pipe", "pipe"] });
    let output = "";
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      resolve({ code: -1, output: output || "таймаут" });
    }, timeoutMs);
    child.stdout.on("data", (b) => { output += b.toString("utf8"); });
    child.stderr.on("data", (b) => { output += b.toString("utf8"); });
    child.on("error", (error) => {
      clearTimeout(timer);
      resolve({ code: -1, output: error.message });
    });
    child.on("exit", (code) => {
      clearTimeout(timer);
      resolve({ code: code ?? -1, output });
    });
  });
}

export async function detectVersion(id) {
  const bin = corePath(id);
  if (!bin || !existsSync(bin)) return "";
  const result = await runCapture(bin, id === "mihomo" ? ["-v"] : ["version"]);
  const line = result.output.split(/\r?\n/).map((l) => l.trim()).find(Boolean) || "";
  return line.slice(0, 180);
}

async function githubLatest(repo) {
  const response = await fetch(`https://api.github.com/repos/${repo}/releases/latest`, {
    headers: { "User-Agent": "stealthsurf-alfa", Accept: "application/vnd.github+json" },
  });
  if (!response.ok) throw new Error(`GitHub ${repo}: ${response.status}`);
  return response.json();
}

function pickAsset(release, test) {
  return (release.assets || []).find((asset) => test(asset.name));
}

export async function downloadCore(id, onProgress) {
  if (id === "ferrum") {
    throw new Error("Ferrum — ядро StealthSurf. Его нет в открытых релизах, положите бинарник в data/cores/ferrum");
  }
  const spec = ENGINES[id];
  if (!spec?.repo) throw new Error("Неизвестное ядро");
  onProgress?.(`смотрю релиз ${spec.repo}`);
  const release = await githubLatest(spec.repo);
  let asset = null;
  if (id === "xray") asset = pickAsset(release, (name) => name === "Xray-linux-64.zip");
  if (id === "sing-box") asset = pickAsset(release, (name) => name.includes("linux-amd64") && name.endsWith(".tar.gz") && !name.includes("musl"));
  if (id === "mihomo") asset = pickAsset(release, (name) => name === `mihomo-linux-amd64-${release.tag_name}.gz` || name === "mihomo-linux-amd64-compatible.gz");
  if (!asset) throw new Error(`В релизе ${release.tag_name} нет файла для linux-amd64`);
  onProgress?.(`скачиваю ${asset.name}`);
  mkdirSync(CORE_DIR, { recursive: true });
  const tmp = join(CORE_DIR, asset.name);
  const response = await fetch(asset.browser_download_url, { headers: { "User-Agent": "stealthsurf-alfa" } });
  if (!response.ok) throw new Error(`загрузка ${asset.name}: ${response.status}`);
  await pipeline(Readable.fromWeb(response.body), createWriteStream(tmp));
  const dest = corePath(id);
  if (asset.name.endsWith(".zip")) {
    await execFile("unzip", ["-o", tmp, spec.bin, "-d", CORE_DIR]);
  } else if (asset.name.endsWith(".tar.gz")) {
    await execFile("tar", ["-xzf", tmp, "-C", CORE_DIR, "--strip-components=1", "--wildcards", `*/${spec.bin}`]);
  } else if (asset.name.endsWith(".gz")) {
    await pipeline(createReadStream(tmp), createGunzip(), createWriteStream(dest));
  }
  if (!existsSync(dest)) throw new Error("архив распаковался без бинарника");
  await execFile("chmod", ["755", dest]);
  rmSync(tmp, { force: true });
  const version = await detectVersion(id);
  return { version: version || release.tag_name, bytes: statSync(dest).size, tag: release.tag_name };
}

