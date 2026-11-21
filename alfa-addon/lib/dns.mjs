import dgram from "node:dgram";
import { Resolver } from "node:dns/promises";
import { evaluate } from "./policy.mjs";
import { dnsServers } from "./policy.mjs";

const nextIp = { n: 1 };

export function rememberFake(live, host) {
  if (!live.fakeToHost) live.fakeToHost = new Map();
  if (!live.hostToFake) live.hostToFake = new Map();
  if (live.hostToFake.has(host)) return live.hostToFake.get(host);
  const n = nextIp.n++;
  const ip = `198.18.${(n >> 8) & 255}.${n & 255}`;
  live.hostToFake.set(host, ip);
  live.fakeToHost.set(ip, host);
  return ip;
}

export function startDns(ctx) {
  const socket = dgram.createSocket("udp4");
  socket.on("message", (msg, rinfo) => {
    handle(ctx, msg, rinfo).then((response) => {
      if (response) socket.send(response, rinfo.port, rinfo.address);
    }).catch((error) => ctx.hooks.log?.("error", `DNS: ${error.message}`));
  });
  socket.on("error", (error) => ctx.hooks.log?.("error", `DNS: ${error.message}`));
  return new Promise((resolve, reject) => {
    socket.once("error", reject);
    socket.bind(5353, "0.0.0.0", () => {
      socket.off("error", reject);
      resolve({
        port: 5353,
        stop() { socket.close(); },
      });
    });
  });
}

async function handle(ctx, msg, rinfo) {
  if (msg.length < 12) return null;
  const id = msg.readUInt16BE(0);
  const question = readQuestion(msg);
  if (!question) return null;
  const name = question.name.toLowerCase();
  const decision = evaluate(ctx.state, {
    host: name,
    port: 53,
    network: "udp",
    clientIp: rinfo.address,
    protocol: "dns",
  });
  if (decision.action === "block" || (ctx.state.router.adblock && decision.ruleId === "ads")) {
    ctx.hooks.blockedAd?.(name, decision);
    return encode(id, question, msg, ["0.0.0.0"], []);
  }
  if (ctx.state.router.ipv6 === "block" && question.type === 28) return encode(id, question, msg, [], []);
  if (ctx.state.connection.ipv4Only && question.type === 28) return encode(id, question, msg, [], []);
  if (ctx.state.engine.fakeIp && (question.type === 1 || question.type === 255)) {
    const ip = rememberFake(ctx.live, name);
    return encode(id, question, msg, [ip], []);
  }
  const { primary, fallback } = dnsServers(ctx.state);
  const looked = await resolveName(name, question.type, ctx.state.router.dnsViaVpn ? primary : fallback, fallback);
  return encode(id, question, msg, looked.a, looked.aaaa);
}

async function resolveName(name, type, servers, fallback) {
  const query = async (list) => {
    const resolver = new Resolver();
    resolver.setServers(list);
    const a = type === 28 ? [] : await resolver.resolve4(name).catch(() => []);
    const aaaa = type === 1 || type === 28 ? await resolver.resolve6(name).catch(() => []) : [];
    return { a, aaaa: type === 28 || type === 1 || type === 255 ? aaaa : [] };
  };
  try {
    const first = await query(servers);
    if (first.a.length || first.aaaa.length) return first;
    return await query(fallback);
  } catch {
    return { a: [], aaaa: [] };
  }
}

function readQuestion(msg) {
  let offset = 12;
  const labels = [];
  while (offset < msg.length) {
    const len = msg[offset];
    if (len === 0) { offset += 1; break; }
    if ((len & 0xc0) === 0xc0) return null;
    offset += 1;
    labels.push(msg.slice(offset, offset + len).toString("utf8"));
    offset += len;
  }
  if (offset + 4 > msg.length) return null;
  const type = msg.readUInt16BE(offset);
  const klass = msg.readUInt16BE(offset + 2);
  return { name: labels.join("."), type, klass, qEnd: offset + 4 };
}

function encode(id, question, request, a, aaaa) {
  const answers = [];
  if (question.type === 1 || question.type === 255) {
    for (const ip of a) answers.push(record(question.name, 1, ip.split(".").map((n) => Number(n))));
  }
  if (question.type === 28 || question.type === 255) {
    for (const ip of aaaa) answers.push(record(question.name, 28, ipv6Bytes(ip)));
  }
  const header = Buffer.alloc(12);
  header.writeUInt16BE(id, 0);
  header.writeUInt16BE(0x8180, 2);
  header.writeUInt16BE(1, 4);
  header.writeUInt16BE(answers.length, 6);
  const questionBytes = request.slice(12, question.qEnd);
  return Buffer.concat([header, questionBytes, ...answers]);
}

function record(name, type, bytes) {
  const labels = name.split(".").filter(Boolean).map((part) => Buffer.concat([Buffer.from([part.length]), Buffer.from(part)]));
  const head = Buffer.concat([...labels, Buffer.from([0])]);
  const meta = Buffer.alloc(10);
  meta.writeUInt16BE(type, 0);
  meta.writeUInt16BE(1, 2);
  meta.writeUInt32BE(60, 4);
  meta.writeUInt16BE(bytes.length, 8);
  return Buffer.concat([head, meta, Buffer.from(bytes)]);
}

function ipv6Bytes(ip) {
  const full = ip.includes("::") ? expand(ip) : ip;
  const parts = full.split(":");
  const out = Buffer.alloc(16);
  parts.forEach((part, i) => out.writeUInt16BE(parseInt(part || "0", 16), i * 2));
  return out;
}

function expand(ip) {
  const [left, right] = ip.split("::");
  const l = left ? left.split(":") : [];
  const r = right ? right.split(":") : [];
  const missing = 8 - l.length - r.length;
  return [...l, ...Array(missing).fill("0"), ...r].join(":");
}
