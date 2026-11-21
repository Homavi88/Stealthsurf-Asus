import net from "node:net";
import { evaluate } from "./policy.mjs";
import { ENGINE_PORT, engineRunning } from "./engines.mjs";
import { isIpv4 } from "./catalog.mjs";

function listen(server, port, host) {
  return new Promise((resolve, reject) => {
    const onError = (error) => {
      server.off("listening", onListening);
      reject(error);
    };
    const onListening = () => {
      server.off("error", onError);
      resolve(port);
    };
    server.once("error", onError);
    server.once("listening", onListening);
    server.listen(port, host);
  });
}

async function listenFree(server, host, port, avoid = new Set()) {
  for (let candidate = port; candidate <= port + 40; candidate += 1) {
    if (avoid.has(candidate)) continue;
    try {
      return await listen(server, candidate, host);
    } catch (error) {
      if (error.code !== "EADDRINUSE") throw error;
    }
  }
  throw new Error("нет свободного порта прокси");
}

export async function startEdge(ctx) {
  const host = ctx.state.connection.shareLan ? "0.0.0.0" : "127.0.0.1";
  const socks = net.createServer((socket) => handleSocks(socket, ctx));
  const http = net.createServer((socket) => handleHttp(socket, ctx));
  const socksPort = await listenFree(socks, host, Number(ctx.state.engine.socksPort || 20808));
  let httpPort;
  try {
    httpPort = await listenFree(http, host, Number(ctx.state.engine.httpPort || 20809), new Set([socksPort]));
  } catch (error) {
    socks.close();
    throw error;
  }
  socks.on("error", (error) => ctx.hooks.log("error", `SOCKS: ${error.message}`));
  http.on("error", (error) => ctx.hooks.log("error", `HTTP-прокси: ${error.message}`));
  return {
    host,
    socksPort,
    httpPort,
    stop() {
      for (const server of [socks, http]) {
        server.close();
        for (const socket of server._connections ? [] : []) socket.destroy();
      }
      socks.close();
      http.close();
    },
  };
}

function arm(socket) {
  socket.on("error", () => socket.destroy());
  return socket;
}

function handleSocks(socket, ctx) {
  arm(socket);
  socket.once("data", (hello) => {
    if (hello[0] !== 5) { socket.destroy(); return; }
    socket.write(Buffer.from([5, 0]));
    socket.once("data", (req) => {
      const cmd = req[1];
      const atyp = req[3];
      let host = "";
      let offset = 4;
      if (atyp === 1) {
        host = Array.from(req.slice(4, 8)).join(".");
        offset = 8;
      } else if (atyp === 3) {
        const len = req[4];
        host = req.slice(5, 5 + len).toString("utf8");
        offset = 5 + len;
      } else if (atyp === 4) {
        const parts = [];
        for (let i = 0; i < 16; i += 2) parts.push(req.readUInt16BE(4 + i).toString(16));
        host = parts.join(":");
        offset = 20;
      } else {
        reply(socket, 8);
        return;
      }
      const port = req.readUInt16BE(offset);
      if (cmd === 3) {
        handleSocksUdp(socket, ctx);
        return;
      }
      if (cmd !== 1) {
        reply(socket, 7);
        return;
      }
      openPath(ctx, socket, { host, port, network: "tcp", clientIp: socket.remoteAddress }, (upstream, decision) => {
        if (!upstream) {
          reply(socket, decision.action === "block" ? 2 : 5);
          socket.end();
          return;
        }
        reply(socket, 0);
        pump(socket, upstream, ctx, decision);
      });
    });
  });
}

import dgram from "node:dgram";

function handleSocksUdp(socket, ctx) {
  const relay = dgram.createSocket("udp4");
  relay.on("error", () => relay.close());
  relay.bind(0, "127.0.0.1", () => {
    const addr = relay.address();
    const port = Buffer.alloc(2);
    port.writeUInt16BE(addr.port);
    const ip = Buffer.from(String(addr.address).split(".").map((n) => Number(n)));
    socket.write(Buffer.concat([Buffer.from([5, 0, 0, 1]), ip, port]));
  });
  relay.on("message", (msg) => {
    if (msg.length < 10 || msg[2] !== 0) return;
    const atyp = msg[3];
    let host = "";
    let offset = 4;
    if (atyp === 1) {
      host = Array.from(msg.slice(4, 8)).join(".");
      offset = 8;
    } else if (atyp === 3) {
      const len = msg[4];
      host = msg.slice(5, 5 + len).toString("utf8");
      offset = 5 + len;
    } else return;
    const port = msg.readUInt16BE(offset);
    const decision = decide(ctx, { host, port, network: "udp", clientIp: socket.remoteAddress });
    ctx.hooks.flow?.({ ...decision, host, port, network: "udp", bytes: msg.length });
  });
  socket.on("close", () => { try { relay.close(); } catch { /* already closed */ } });
}

function reply(socket, code) {
  socket.write(Buffer.from([5, code, 0, 1, 0, 0, 0, 0, 0, 0]));
}

function handleHttp(socket, ctx) {
  arm(socket);
  let buffer = Buffer.alloc(0);
  const onData = (chunk) => {
    buffer = Buffer.concat([buffer, chunk]);
    const idx = buffer.indexOf("\r\n\r\n");
    if (idx < 0) {
      if (buffer.length > 1024 * 256) socket.destroy();
      return;
    }
    socket.off("data", onData);
    const head = buffer.slice(0, idx).toString("utf8");
    const rest = buffer.slice(idx + 4);
    const [start] = head.split("\r\n");
    const [method, target] = start.split(" ");
    if (!method || !target) { socket.end("HTTP/1.1 400 Bad Request\r\n\r\n"); return; }
    if (method.toUpperCase() === "CONNECT") {
      const [host, portRaw] = target.split(":");
      openPath(ctx, socket, { host, port: Number(portRaw || 443), network: "tcp", clientIp: socket.remoteAddress }, (upstream, decision) => {
        if (!upstream) {
          const code = decision.action === "block" ? 403 : 502;
          socket.end(`HTTP/1.1 ${code} ${decision.reason}\r\nContent-Type: text/plain; charset=utf-8\r\nConnection: close\r\n\r\n${decision.reason}`);
          return;
        }
        socket.write("HTTP/1.1 200 Connection Established\r\n\r\n");
        if (rest.length) upstream.write(rest);
        pump(socket, upstream, ctx, decision);
      });
      return;
    }
    let url;
    try { url = new URL(target); } catch { socket.end("HTTP/1.1 400 Bad Request\r\n\r\n"); return; }
    const headers = rewriteHeaders(head, url);
    openPath(ctx, socket, { host: url.hostname, port: Number(url.port || 80), network: "tcp", clientIp: socket.remoteAddress }, (upstream, decision) => {
      if (!upstream) {
        socket.end(`HTTP/1.1 403 ${decision.reason}\r\nContent-Type: text/plain; charset=utf-8\r\nConnection: close\r\n\r\n${decision.reason}`);
        return;
      }
      const length = Number(/content-length:\s*(\d+)/i.exec(head)?.[1] || 0);
      const body = rest.subarray(0, length);
      upstream.write(`${method} ${url.pathname}${url.search} HTTP/1.1\r\n${headers}\r\n\r\n`);
      if (body.length) upstream.write(body);
      pumpDown(socket, upstream, ctx, decision);
    });
  };
  socket.on("data", onData);
}

function rewriteHeaders(head, url) {
  const lines = head.split("\r\n").slice(1).filter((line) => !/^proxy-connection:/i.test(line) && !/^connection:/i.test(line));
  let hasHost = false;
  const next = lines.map((line) => {
    if (/^host:/i.test(line)) { hasHost = true; return `Host: ${url.host}`; }
    return line;
  });
  if (!hasHost) next.unshift(`Host: ${url.host}`);
  next.push("Connection: close");
  return next.join("\r\n");
}

export function dialTarget(ctx, host) {
  return ctx.live?.fakeToHost?.get(host) || host;
}

function decide(ctx, req) {
  const host = dialTarget(ctx, req.host);
  return { ...evaluate(ctx.state, { ...req, host }), dialHost: host };
}

function openPath(ctx, socket, req, done) {
  let decision;
  try { decision = decide(ctx, req); }
  catch (error) {
    done(null, { action: "block", reason: error.message });
    return;
  }
  const host = decision.dialHost || dialTarget(ctx, req.host);
  ctx.hooks.flow?.({ ...decision, host, port: req.port, network: req.network, clientIp: req.clientIp });
  if (decision.action === "block") {
    done(null, decision);
    return;
  }
  const viaEngine = decision.action === "proxy" && ctx.live.tunnel === "engine" && engineRunning();
  const connector = viaEngine
    ? chainSocks(host, req.port)
    : directConnect(host, req.port);
  connector.then((upstream) => {
    upstream.on("error", () => socket.destroy());
    done(upstream, { ...decision, viaEngine });
  }).catch((error) => {
    ctx.hooks.log?.("error", `${req.host}:${req.port} — ${error.message}`);
    done(null, { ...decision, action: "block", reason: "Туннель недоступен" });
  });
}

function directConnect(host, port) {
  return new Promise((resolve, reject) => {
    const socket = net.connect({ host, port });
    const fail = (error) => { socket.destroy(); reject(error); };
    socket.once("error", fail);
    socket.once("connect", () => {
      socket.off("error", fail);
      resolve(socket);
    });
  });
}

function chainSocks(host, port) {
  return new Promise((resolve, reject) => {
    const socket = net.connect(ENGINE_PORT, "127.0.0.1");
    const fail = (error) => { socket.destroy(); reject(error); };
    socket.once("error", fail);
    socket.once("connect", () => {
      socket.write(Buffer.from([5, 1, 0]));
    });
    const chunks = [];
    const onData = (buf) => {
      chunks.push(buf);
      const data = Buffer.concat(chunks);
      if (data.length < 2) return;
      if (step === 0) {
        step = 1;
        chunks.length = 0;
        socket.write(socksRequest(host, port));
        if (data.length > 2) chunks.push(data.slice(2));
        return;
      }
      if (data.length < 4) return;
      const atyp = data[3];
      let need = 6;
      if (atyp === 1) need = 10;
      else if (atyp === 3) need = 7 + data[4];
      else if (atyp === 4) need = 22;
      if (data.length < need) return;
      socket.off("data", onData);
      if (data[1] !== 0) { fail(new Error(`ядро отказало в SOCKS (${data[1]})`)); return; }
      socket.off("error", fail);
      const extra = data.slice(need);
      if (extra.length) socket.unshift(extra);
      resolve(socket);
    };
    let step = 0;
    socket.on("data", onData);
  });
}

function socksRequest(host, port) {
  let addr;
  if (isIpv4(host)) {
    addr = Buffer.concat([Buffer.from([1]), Buffer.from(host.split(".").map((n) => Number(n)))]);
  } else if (host.includes(":")) {
    addr = Buffer.concat([Buffer.from([4]), Buffer.from(host.split(":").flatMap((p) => {
      const n = parseInt(p || "0", 16);
      return [(n >> 8) & 255, n & 255];
    }))]);
  } else {
    const name = Buffer.from(host);
    addr = Buffer.concat([Buffer.from([3, name.length]), name]);
  }
  const p = Buffer.alloc(2);
  p.writeUInt16BE(port);
  return Buffer.concat([Buffer.from([5, 1, 0]), addr, p]);
}

function pumpDown(client, upstream, ctx, decision) {
  const lane = decision.action === "proxy" ? "vpn" : "direct";
  upstream.on("data", (chunk) => {
    ctx.hooks.bytes?.(lane, "down", chunk.length, decision);
    if (!client.write(chunk)) upstream.pause();
  });
  client.on("drain", () => upstream.resume());
  client.on("data", () => {});
  const close = () => { client.destroy(); upstream.destroy(); };
  client.on("close", () => upstream.destroy());
  upstream.on("close", () => client.end());
  client.on("error", close);
  upstream.on("error", close);
}

function pump(client, upstream, ctx, decision) {
  const lane = decision.action === "proxy" ? "vpn" : "direct";
  const count = (dir, size) => ctx.hooks.bytes?.(lane, dir, size, decision);
  client.on("data", (chunk) => {
    count("up", chunk.length);
    if (!upstream.write(chunk)) client.pause();
  });
  upstream.on("data", (chunk) => {
    count("down", chunk.length);
    if (!client.write(chunk)) upstream.pause();
  });
  upstream.on("drain", () => client.resume());
  client.on("drain", () => upstream.resume());
  const close = () => { client.destroy(); upstream.destroy(); };
  client.on("close", () => upstream.destroy());
  upstream.on("close", () => client.destroy());
  client.on("error", close);
  upstream.on("error", close);
}

