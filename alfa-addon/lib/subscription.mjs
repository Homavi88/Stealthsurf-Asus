import { createHash } from "node:crypto";

function safeName(value, fallback) {
  const text = decodeURIComponentSafe(value || "").trim();
  return text || fallback;
}

function decodeURIComponentSafe(value) {
  try { return decodeURIComponent(value); } catch { return value; }
}

function parseQuery(search) {
  const out = {};
  const raw = search.startsWith("?") ? search.slice(1) : search;
  if (!raw) return out;
  for (const part of raw.split("&")) {
    const [k, v = ""] = part.split("=");
    out[decodeURIComponentSafe(k)] = decodeURIComponentSafe(v);
  }
  return out;
}

export function nodeIdentity(node) {
  return [node.protocol || "", node.host || "", node.port || "", node.name || ""].join("|");
}

function nodeBase(partial) {
  const id = createHash("sha1").update(nodeIdentity(partial)).digest("hex").slice(0, 12);
  return {
    country: "",
    flag: "",
    until: "",
    online: true,
    alpha: false,
    ...partial,
    id: partial.id || id,
  };
}

export function parseShareLink(line) {
  const text = String(line || "").trim();
  if (!text || text.startsWith("#") || text.startsWith("//")) return null;
  if (text.startsWith("vless://")) return parseVless(text);
  if (text.startsWith("trojan://")) return parseTrojan(text);
  if (text.startsWith("vmess://")) return parseVmess(text);
  if (text.startsWith("ss://")) return parseSs(text);
  if (text.startsWith("hysteria2://") || text.startsWith("hy2://")) return parseHy2(text);
  if (text.startsWith("tuic://")) return parseTuic(text);
  if (text.startsWith("wg://") || text.startsWith("wireguard://")) return parseWg(text);
  return null;
}

function parseVless(text) {
  const url = new URL(text);
  const params = parseQuery(url.search);
  return nodeBase({
    name: safeName(url.hash.slice(1), `VLESS ${url.hostname}`),
    protocol: "vless",
    host: url.hostname,
    port: Number(url.port || 443),
    uuid: decodeURIComponentSafe(url.username),
    flow: params.flow || "",
    transport: params.type || "tcp",
    security: params.security || "none",
    sni: params.sni || params.host || "",
    path: params.path || "",
    serviceName: params.serviceName || params.service || "",
    publicKey: params.pbk || "",
    shortId: params.sid || "",
    fingerprint: params.fp || "",
    alpn: params.alpn || "",
  });
}

function parseTrojan(text) {
  const url = new URL(text);
  const params = parseQuery(url.search);
  return nodeBase({
    name: safeName(url.hash.slice(1), `Trojan ${url.hostname}`),
    protocol: "trojan",
    host: url.hostname,
    port: Number(url.port || 443),
    password: decodeURIComponentSafe(url.username),
    transport: params.type || "tcp",
    security: params.security || "tls",
    sni: params.sni || params.host || url.hostname,
    path: params.path || "",
    fingerprint: params.fp || "",
    alpn: params.alpn || "",
  });
}

function parseHy2(text) {
  const url = new URL(text);
  const params = parseQuery(url.search);
  return nodeBase({
    name: safeName(url.hash.slice(1), `Hysteria ${url.hostname}`),
    protocol: "hysteria2",
    host: url.hostname,
    port: Number(url.port || 443),
    password: decodeURIComponentSafe(url.username),
    sni: params.sni || url.hostname,
    alpn: params.alpn || "h3",
    insecure: params.insecure === "1",
  });
}

function parseTuic(text) {
  const url = new URL(text);
  const params = parseQuery(url.search);
  return nodeBase({
    name: safeName(url.hash.slice(1), `TUIC ${url.hostname}`),
    protocol: "tuic",
    host: url.hostname,
    port: Number(url.port || 443),
    uuid: decodeURIComponentSafe(url.username),
    password: decodeURIComponentSafe(url.password || params.password || ""),
    sni: params.sni || url.hostname,
    congestion: params.congestion_control || "bbr",
  });
}

function parseWg(text) {
  const url = new URL(text);
  const params = parseQuery(url.search);
  return nodeBase({
    name: safeName(url.hash.slice(1), `WireGuard ${url.hostname}`),
    protocol: params.amnezia ? "amneziawg" : "wireguard",
    host: url.hostname,
    port: Number(url.port || 51820),
    privateKey: params.privateKey || decodeURIComponentSafe(url.username),
    peerKey: params.publicKey || params.peer || "",
    address: params.address || "10.0.0.2/32",
    reserved: params.reserved || "",
    mtu: Number(params.mtu || 1280),
  });
}

function parseVmess(text) {
  const payload = text.slice("vmess://".length);
  const json = JSON.parse(Buffer.from(payload, "base64").toString("utf8"));
  return nodeBase({
    name: json.ps || `VMess ${json.add}`,
    protocol: "vmess",
    host: json.add,
    port: Number(json.port || 443),
    uuid: json.id,
    alterId: Number(json.aid || 0),
    security: json.tls || "none",
    transport: json.net || "tcp",
    path: json.path || "",
    hostHeader: json.host || "",
    sni: json.sni || json.host || "",
    fingerprint: json.fp || "",
  });
}

function parseSs(text) {
  const raw = text.slice("ss://".length);
  const hashIdx = raw.indexOf("#");
  const body = hashIdx >= 0 ? raw.slice(0, hashIdx) : raw;
  const name = hashIdx >= 0 ? safeName(raw.slice(hashIdx + 1), "Shadowsocks") : "Shadowsocks";
  let userinfo = body;
  let hostport = "";
  if (body.includes("@")) {
    const [enc, rest] = body.split("@");
    userinfo = Buffer.from(enc, "base64").toString("utf8");
    hostport = rest;
  } else {
    const decoded = Buffer.from(body, "base64").toString("utf8");
    const at = decoded.lastIndexOf("@");
    userinfo = decoded.slice(0, at);
    hostport = decoded.slice(at + 1);
  }
  const method = userinfo.slice(0, userinfo.indexOf(":"));
  const password = userinfo.slice(userinfo.indexOf(":") + 1);
  const url = new URL(`ss://${hostport}`);
  return nodeBase({
    name,
    protocol: "shadowsocks",
    host: url.hostname,
    port: Number(url.port || 8388),
    method,
    password,
  });
}

export function parseSubscriptionBody(body) {
  const text = String(body || "").trim();
  if (!text) return [];
  let decoded = text;
  if (!text.includes("://")) {
    try {
      const attempt = Buffer.from(text.replace(/\s/g, ""), "base64").toString("utf8");
      if (attempt.includes("://")) decoded = attempt;
    } catch { /* keep original */ }
  }
  if (decoded.includes("proxies:")) return parseClash(decoded);
  return decoded
    .split(/\r?\n/)
    .map(parseShareLink)
    .filter(Boolean);
}

function parseClash(text) {
  const nodes = [];
  const chunks = text.split(/\n\s*-\s+/).slice(1);
  for (const chunk of chunks) {
    const pick = (key) => {
      const match = chunk.match(new RegExp(`(?:^|\\n)\\s*${key}:\\s*([^\\n#]+)`));
      return match ? match[1].trim().replace(/^['"]|['"]$/g, "") : "";
    };
    const type = pick("type");
    if (!type || type === "select" || type === "url-test") continue;
    const name = pick("name") || `${type} ${pick("server")}`;
    const protocol = type === "ss" ? "shadowsocks" : type === "hy2" ? "hysteria2" : type;
    nodes.push(nodeBase({
      name,
      protocol,
      host: pick("server"),
      port: Number(pick("port") || 443),
      uuid: pick("uuid"),
      password: pick("password"),
      method: pick("cipher") || pick("method"),
      sni: pick("sni") || pick("servername"),
      transport: pick("network") || "tcp",
      security: pick("tls") === "true" ? "tls" : pick("security") || "",
      flow: pick("flow"),
      publicKey: pick("public-key") || pick("reality-public-key"),
      shortId: pick("short-id"),
    }));
  }
  return nodes.filter((node) => node.host);
}

export function parseWireGuardIni(text) {
  const get = (section, key) => {
    const re = new RegExp(`\\[${section}\\][\\s\\S]*?${key}\\s*=\\s*([^\\n]+)`, "i");
    const match = text.match(re);
    return match ? match[1].trim() : "";
  };
  const endpoint = get("Peer", "Endpoint");
  const [host, port] = endpoint.split(":");
  if (!host || !get("Peer", "PublicKey") || !get("Interface", "PrivateKey")) {
    throw new Error("В профиле нужны PrivateKey, PublicKey и Endpoint");
  }
  return nodeBase({
    name: "WARP",
    protocol: "wireguard",
    host,
    port: Number(port || 2408),
    privateKey: get("Interface", "PrivateKey"),
    peerKey: get("Peer", "PublicKey"),
    address: get("Interface", "Address") || "172.16.0.2/32",
    mtu: Number(get("Interface", "MTU") || 1280),
    reserved: "",
  });
}
