import { randomBytes, randomUUID } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync, rmSync, existsSync, statSync } from "node:fs";
import { join } from "node:path";
import dgram from "node:dgram";
import net from "node:net";
import tls from "node:tls";
import http from "node:http";
import os from "node:os";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import {
  appendLog,
  assertPatch,
  checkPassword,
  DEFAULT_PANEL_PASSWORD,
  findNode,
  hashPassword,
  loadState,
  passwordNeedsUpgrade,
  publicState,
  saveState,
  setPath,
  visibleNodes,
  DATA,
} from "./state.mjs";
import { OPEN_PANEL } from "./catalog.mjs";
import { evaluate } from "./policy.mjs";
import { nodeIdentity, parseShareLink, parseSubscriptionBody, parseWireGuardIni } from "./subscription.mjs";
import {
  GEO_DIR,
  coreStatus,
  detectVersion,
  downloadCore,
  engineRunning,
  startEngine,
  stopEngine,
  testConfig,
  waitForPort,
  writeConfigs,
  ENGINE_PORT,
} from "./engines.mjs";
import { startEdge } from "./proxy.mjs";
import { startDns } from "./dns.mjs";
import { ENGINES, engineSupports, pickEngine } from "./catalog.mjs";

const exec = promisify(execFile);

export function createRuntime() {
  const state = loadState();
  const live = {
    sse: new Set(),
    history: [],
    rates: emptyBytes(),
    totals: emptyBytes(),
    window: emptyBytes(),
    session: emptyBytes(),
    publicIp: "",
    exitIp: "",
    load: { cpu: 0, ramUsed: 0, ramTotal: os.totalmem(), proc: 0 },
    tunnel: "off",
    engineId: null,
    engineMessage: "",
    conns: [],
    fakeToHost: new Map(),
    hostToFake: new Map(),
    edge: null,
    dns: null,
    cpuPrev: os.cpus(),
    healthFails: 0,
    startedAt: Date.now(),
    pairCodes: new Map(),
    httpPort: state.engine.httpPort,
    socksPort: state.engine.socksPort,
  };

  const ctx = {
    state,
    live,
    hooks: {
      log: (level, msg) => {
        appendLog(state, level, msg);
        saveState(state);
        broadcast({ type: "log", level, msg, t: Date.now() });
      },
      bytes: (lane, dir, size, decision) => {
        const key = `${lane}${dir === "up" ? "Up" : "Down"}`;
        live.window[key] += size;
        live.totals[key] += size;
        live.session[key] += size;
        const device = decision?.device;
        if (device?.traffic) {
          device.traffic.session += size;
          device.traffic.today += size;
          device.traffic.d7 += size;
          device.traffic.d30 += size;
        }
      },
      flow: (info) => noteFlow(info),
      blockedAd: (host) => noteAd(host),
    },
  };

  function noteAd(host) {
    const stats = state.router.adStats;
    stats.today += 1;
    stats.week += 1;
    stats.top[host] = (stats.top[host] || 0) + 1;
    stats.recent.unshift({ host, t: Date.now() });
    stats.recent = stats.recent.slice(0, 30);
    saveState(state);
  }

  function noteFlow(info) {
    const row = {
      t: Date.now(),
      host: info.host,
      port: info.port,
      network: info.network,
      action: info.action,
      reason: info.reason,
      clientIp: normalizeClient(info.clientIp),
      deviceId: info.device?.id || null,
    };
    live.conns.unshift(row);
    if (live.conns.length > 200) live.conns.length = 200;
    if (info.action === "block" && info.ruleId === "ads") noteAd(info.host);
  }

  function broadcast(event) {
    const data = `data: ${JSON.stringify(event)}\n\n`;
    for (const res of live.sse) res.write(data);
  }

  function snapshot() {
    return publicState(state, runtimeView());
  }

  function runtimeView() {
    return {
      tunnel: live.tunnel,
      engineId: live.engineId,
      engineMessage: live.engineMessage,
      engineUp: engineRunning(),
      rates: live.rates,
      session: live.session,
      totals: live.totals,
      history: live.history.slice(-120),
      publicIp: live.publicIp,
      exitIp: live.exitIp || state.vpn.exitIp,
      load: live.load,
      conns: live.conns.slice(0, 80),
      httpPort: live.httpPort,
      socksPort: live.socksPort,
      cores: coreStatus(state),
      nodes: visibleNodes(state),
      uptime: Date.now() - live.startedAt,
      panelPort: 8788,
    };
  }

  function tick() {
    const cpu = cpuPercent();
    const free = os.freemem();
    live.load = {
      cpu,
      ramUsed: os.totalmem() - free,
      ramTotal: os.totalmem(),
      proc: process.memoryUsage().rss,
    };
    live.rates = { ...live.window };
    live.history.push({ t: Date.now(), ...live.rates });
    if (live.history.length > 180) live.history.splice(0, live.history.length - 180);
    live.window = emptyBytes();
    broadcast({ type: "tick", runtime: runtimeView(), connected: state.vpn.connected, directMode: state.vpn.directMode });
  }

  function cpuPercent() {
    const now = os.cpus();
    let idle = 0;
    let total = 0;
    now.forEach((core, i) => {
      const prev = live.cpuPrev[i] || core;
      const idleD = core.times.idle - prev.times.idle;
      const totalD = sum(Object.values(core.times)) - sum(Object.values(prev.times));
      idle += idleD;
      total += totalD;
    });
    live.cpuPrev = now;
    if (!total) return 0;
    return Math.max(0, Math.min(100, Math.round((1 - idle / total) * 100)));
  }

  async function boot() {
    live.timer = setInterval(tick, 1000);
    live.slow = setInterval(() => { slowLoop().catch((error) => ctx.hooks.log("error", error.message)); }, 20000);
    for (const id of ["xray", "ferrum", "sing-box", "mihomo"]) {
      const status = coreStatus(state)[id];
      if (status?.installed) {
        const version = await detectVersion(id);
        state.engine.cores[id] = { ...(state.engine.cores[id] || {}), version, bytes: status.bytes, at: state.engine.cores[id]?.at || Date.now() };
      }
    }
    if (state.connection.onBoot && (state.wasConnected || state.vpn.directMode)) {
      await connect().catch((error) => ctx.hooks.log("error", error.message));
    }
    refreshPublicIp().catch(() => {});
    ctx.hooks.log("info", `Альфа ${state.version} слушает панель на порту 8788`);
  }

  async function shutdown() {
    clearInterval(live.timer);
    clearInterval(live.slow);
    await disconnect({ silent: true });
    if (live.dns) {
      try { live.dns.stop(); } catch { /* already closed */ }
      live.dns = null;
    }
  }

  async function slowLoop() {
    applySchedule();
    if (state.vpn.connected && state.diagnostics.tunnelCheck) await healthCheck();
    if (state.router.ha && state.router.mqtt.host) await publishHa().catch(() => {});
  }

  function applySchedule() {
    if (!state.router.scheduleEnabled) return;
    const hour = new Date().getHours();
    const allowed = state.router.scheduleHours[hour] !== false;
    if (!allowed && state.vpn.connected) return disconnect({ scheduled: true });
    if (allowed && !state.vpn.connected && (state.wasConnected || state.vpn.pausedBySchedule)) return connect();
  }

  async function healthCheck() {
    if (live.tunnel !== "engine" && state.vpn.directMode) return;
    const node = findNode(state).node;
    const host = node?.probeHost || node?.host;
    const port = node?.probePort || node?.port || 443;
    if (!host || node?.protocol === "direct") return;
    const ms = await tcpPing(host, port, 2000);
    if (ms == null) {
      live.healthFails += 1;
      ctx.hooks.log("warning", `Проверка туннеля не прошла (${live.healthFails})`);
      if (live.healthFails >= 3 && state.router.reserveId) {
        live.healthFails = 0;
        ctx.hooks.log("warning", "Включаю резервный конфиг");
        await selectNode(state.router.reserveId, { force: true });
        return;
      }
      if (live.healthFails >= 3 && state.other.autoSetup) {
        live.healthFails = 0;
        await autoSetup();
      }
    } else live.healthFails = 0;
  }

  async function autoSetup() {
    const nodes = visibleNodes(state).filter((n) => n.protocol !== "direct" && n.id !== state.vpn.selectedId);
    let best = null;
    for (const node of nodes) {
      const ms = await tcpPing(node.probeHost || node.host, node.probePort || node.port || 443, 1200);
      if (ms != null && (!best || ms < best.ms)) best = { node, ms };
    }
    if (!best) {
      ctx.hooks.log("warning", "Автонастройка не нашла отвечающий конфиг");
      return { ok: false };
    }
    ctx.hooks.log("info", `Автонастройка выбрала «${best.node.name}» (${best.ms} мс)`);
    await selectNode(best.node.id, { force: true });
    return { ok: true, id: best.node.id, ms: best.ms };
  }

  async function connect() {
    const { node } = findNode(state);
    if (!node) throw new Error("Конфиг не выбран");
    const wanted = pickEngine(state.engine.preference, node.protocol);
    if (node.protocol !== "direct" && !node.alpha && !engineSupports(wanted, node.protocol)) {
      await stopEngine();
      await stopEdge();
      live.tunnel = "off";
      state.vpn.connected = false;
      state.vpn.directMode = false;
      live.engineMessage = `${ENGINES[wanted].title} не умеет протокол ${node.protocol}`;
      saveState(state, true);
      broadcast({ type: "snapshot", state: snapshot() });
      throw new Error(live.engineMessage);
    }
    await stopEdge();
    state.vpn.directMode = node.protocol === "direct";
    state.vpn.selectedId = node.id;
    if (node.protocol !== "direct") state.vpn.lastVpnId = node.id;
    const written = writeConfigs(state, node);
    const engineId = written.choice.id;
    state.engine.active = engineId;
    state.engine.activeReason = engineReason(state, node, engineId);
    live.engineId = engineId;
    await stopEngine();
    live.tunnel = "off";
    if (node.protocol !== "direct") {
      const started = startEngine(engineId, written.activePath, (line) => ctx.hooks.log("debug", line));
      if (started.started) {
        const up = await waitForPort(ENGINE_PORT);
        if (up) {
          live.tunnel = "engine";
          live.engineMessage = `${ENGINES[engineId].title} запущен, pid ${started.pid}`;
        } else {
          await stopEngine();
          live.engineMessage = `${ENGINES[engineId].title} не открыл порт ${ENGINE_PORT}`;
          if (!node.alpha) throw new Error(live.engineMessage);
          live.tunnel = "alpha-direct";
        }
      } else if (node.alpha) {
        live.tunnel = "alpha-direct";
        live.engineMessage = `${started.reason}. Альфа-узел идёт локальным контуром, конфиг ядра уже записан.`;
      } else {
        live.engineMessage = started.reason;
        throw new Error(`${started.reason}. Скачайте ядро в разделе «Движок».`);
      }
    } else {
      live.tunnel = "direct";
      live.engineMessage = "Режим без VPN: туннель не поднимается, обход блокировок и реклама остаются.";
    }
    live.edge = await startEdge(ctx);
    live.httpPort = live.edge.httpPort;
    live.socksPort = live.edge.socksPort;
    if (!live.dns) live.dns = await startDns(ctx).catch((error) => {
      ctx.hooks.log("warning", `DNS 5353: ${error.message}`);
      return null;
    });
    state.vpn.connected = node.protocol !== "direct";
    state.vpn.directMode = node.protocol === "direct";
    state.vpn.pausedBySchedule = false;
    state.vpn.since = Date.now();
    state.wasConnected = node.protocol !== "direct";
    live.session = emptyBytes();
    live.conns = [];
    ctx.hooks.log("info", state.vpn.connected ? `Подключено: ${node.name} через ${engineId}` : "Выбран прямой режим");
    saveState(state, true);
    refreshExitIp().catch(() => {});
    broadcast({ type: "snapshot", state: snapshot() });
    return { ok: true, tunnel: live.tunnel, engine: engineId, message: live.engineMessage };
  }

  async function disconnect({ silent = false, scheduled = false } = {}) {
    await stopEngine();
    await stopEdge();
    live.tunnel = "off";
    live.engineMessage = "";
    state.vpn.connected = false;
    state.vpn.directMode = false;
    state.vpn.since = null;
    if (scheduled) {
      state.vpn.pausedBySchedule = true;
      ctx.hooks.log("info", "Расписание выключило VPN");
    } else if (!silent) {
      state.wasConnected = false;
      state.vpn.pausedBySchedule = false;
      ctx.hooks.log("info", "VPN отключён");
    }
    saveState(state, true);
    broadcast({ type: "snapshot", state: snapshot() });
    return { ok: true };
  }

  async function stopEdge() {
    if (live.edge) {
      live.edge.stop();
      live.edge = null;
    }
  }

  async function selectNode(id, { force = false } = {}) {
    const { node } = findNode(state, id);
    if (!node) throw new Error("Такого конфига нет");
    if (state.engine.preference !== "auto" && !engineSupports(state.engine.preference, node.protocol)) {
      throw new Error(`${ENGINES[state.engine.preference].title} не умеет протокол ${node.protocol}`);
    }
    state.vpn.selectedId = id;
    if (node.protocol !== "direct") state.vpn.lastVpnId = id;
    saveState(state);
    if (force || state.vpn.connected || (state.connection.onSelect && node.protocol !== "direct")) {
      return connect();
    }
    broadcast({ type: "snapshot", state: snapshot() });
    return { ok: true, connected: false };
  }

  async function refreshExitIp() {
    if (!state.vpn.connected || !live.edge) {
      state.vpn.exitIp = live.publicIp;
      return;
    }
    try {
      const ip = (await proxyFetch("https://api.ipify.org")).trim();
      if (/^[0-9a-f:.]+$/i.test(ip)) {
        live.exitIp = ip;
        state.vpn.exitIp = ip;
        saveState(state);
      }
    } catch {
      state.vpn.exitIp = live.publicIp;
    }
  }

  async function refreshPublicIp() {
    try {
      const response = await fetch("https://api.ipify.org", { signal: AbortSignal.timeout(5000) });
      live.publicIp = (await response.text()).trim();
      if (!state.vpn.connected) state.vpn.exitIp = live.publicIp;
    } catch { /* стенд без выхода в сеть */ }
  }

  function proxyFetch(url) {
    const target = new URL(url);
    return new Promise((resolve, reject) => {
      const req = http.request({
        host: "127.0.0.1",
        port: live.httpPort,
        method: "CONNECT",
        path: `${target.hostname}:${target.port || 443}`,
        timeout: 8000,
      });
      req.once("connect", (res, socket) => {
        if (res.statusCode !== 200) { reject(new Error(String(res.statusCode))); return; }
        const secure = tls.connect({ socket, servername: target.hostname }, () => {
          secure.write(`GET ${target.pathname || "/"} HTTP/1.1\r\nHost: ${target.hostname}\r\nConnection: close\r\n\r\n`);
        });
        let data = "";
        secure.on("data", (chunk) => { data += chunk.toString("utf8"); });
        secure.on("end", () => {
          const body = data.split("\r\n\r\n").slice(1).join("\r\n\r\n");
          resolve(body);
        });
        secure.on("error", reject);
      });
      req.once("error", reject);
      req.end();
    });
  }

  async function invoke(command, body = {}) {
    switch (command) {
      case "snapshot":
        return snapshot();
      case "connect":
        return connect();
      case "disconnect":
        return disconnect();
      case "selectNode":
        return selectNode(body.id);
      case "ping":
        return pingOne(body.id);
      case "pingAll":
        return pingAll();
      case "patch":
        return patch(body.path, body.value);
      case "explain":
        return evaluate(state, {
          host: body.host,
          port: Number(body.port || 443),
          network: body.network || "tcp",
          clientIp: body.clientIp || "192.168.50.44",
          protocol: body.protocol || "tcp",
        });
      case "refreshSubscription":
        return refreshSubscription(body.id || state.activeSubscription);
      case "addSubscription":
        return addSubscription(body);
      case "removeSubscription":
        return removeSubscription(body.id);
      case "setSubscription":
        state.activeSubscription = body.id;
        saveState(state);
        return snapshot();
      case "deviceSet":
        return deviceSet(body);
      case "deviceRename":
        return deviceRename(body.id, body.name);
      case "dismissNew":
        state.dismissedNew = state.devices.filter((d) => d.isNew).map((d) => d.id);
        for (const device of state.devices) {
          if (!device.isNew) continue;
          device.isNew = false;
          if (body.keepVpn) continue;
          if (state.router.mode === "except") device.excluded = true;
          else if (state.router.mode === "selected") device.excluded = false;
          else device.route = "direct";
        }
        saveState(state);
        return snapshot();
      case "addRule":
        return addRule(body);
      case "deleteRule":
        state.routing.custom = state.routing.custom.filter((r) => r.id !== body.id);
        if (state.routing.source === "local") state.routing.localDirty = true;
        saveState(state);
        return snapshot();
      case "applyRouting":
        state.routing.localDirty = false;
        state.routing.appliedLocal = true;
        if (state.vpn.connected) await connect();
        else saveState(state);
        return snapshot();
      case "setRoutingSource":
        state.routing.source = body.source === "local" ? "local" : "server";
        if (body.source === "local") state.routing.localDirty = true;
        saveState(state);
        return snapshot();
      case "saveBalancer":
        return saveBalancer(body);
      case "deleteBalancer":
        state.routing.balancers = state.routing.balancers.filter((b) => b.id !== body.id);
        saveState(state);
        return snapshot();
      case "saveConfigRoute":
        state.configRoutes[body.nodeId || state.vpn.selectedId] = { rules: body.rules || [] };
        if (state.vpn.connected) await connect();
        else saveState(state);
        return snapshot();
      case "saveProfile":
        state.profiles.push({ id: randomUUID().slice(0, 8), name: body.name || "Профиль", at: Date.now(), connection: structuredClone(state.connection) });
        saveState(state);
        return snapshot();
      case "applyProfile": {
        const profile = state.profiles.find((p) => p.id === body.id);
        if (!profile) throw new Error("Профиль не найден");
        state.connection = structuredClone(profile.connection);
        saveState(state);
        return snapshot();
      }
      case "deleteProfile":
        state.profiles = state.profiles.filter((p) => p.id !== body.id);
        saveState(state);
        return snapshot();
      case "zapretRecheck":
        return zapretRecheck(body.all === true);
      case "zapretList":
        return zapretList(body);
      case "zapretMethod":
        return zapretMethod(body);
      case "warpCreate":
        state.connection.warpProfile = {
          id: randomUUID().slice(0, 8),
          createdAt: Date.now(),
          method: state.connection.warpMethod,
          status: "local",
          note: "Локальная заготовка. Для настоящего WARP импортируйте профиль wgcf.",
        };
        saveState(state);
        return snapshot();
      case "warpImport":
        state.connection.warpProfile = { ...parseWireGuardIni(body.text || ""), status: "imported", createdAt: Date.now() };
        saveState(state);
        return snapshot();
      case "addBridge":
        state.connection.bridges.push({ id: randomUUID().slice(0, 8), from: body.from || state.vpn.selectedId, to: body.to });
        if (state.vpn.connected) await connect();
        else saveState(state);
        return snapshot();
      case "deleteBridge":
        state.connection.bridges = state.connection.bridges.filter((b) => b.id !== body.id);
        saveState(state);
        return snapshot();
      case "wol":
        return wake(body.mac || body.id);
      case "mqttTest":
        return publishHa(true);
      case "automode":
        return runAutomode();
      case "detectNetwork":
        state.netAuto.current = await detectNetwork();
        if (state.netAuto.enabled) await applyNetAuto();
        saveState(state);
        return snapshot();
      case "speedTest":
        return speedTest();
      case "leakTest":
        return leakTest();
      case "resetNetwork":
        return resetNetwork();
      case "clearLogs":
        state.logs = [];
        live.conns = [];
        saveState(state);
        return snapshot();
      case "downloadCore":
        return fetchCore(body.id);
      case "deleteCore":
        return removeCore(body.id);
      case "testCore":
        writeConfigs(state, findNode(state).node);
        return testConfig(body.id);
      case "updateGeo":
        return updateGeo(body.url);
      case "checkUpdates":
        state.updates.lastCheck = Date.now();
        state.updates.latest = state.version;
        saveState(state);
        return { ok: true, latest: state.version, message: "Альфа уже локальная сборка, обновление с витрины не требуется." };
      case "feedback":
        return saveFeedback(body);
      case "setPassword":
        return setPassword(body);
      case "pair":
        return makePair();
      case "export":
        return exportSettings();
      case "import":
        return importSettings(body.settings || body);
      case "configs":
        return readConfigs();
      case "autoSetup":
        return autoSetup();
      default:
        throw new Error(`Неизвестная команда ${command}`);
    }
  }

  async function patch(path, value) {
    assertPatch(path);
    setPath(state, path, value);
    if (path === "routing.source") state.routing.localDirty = value === "local";
    if (path.startsWith("routing.") && state.routing.source === "local") state.routing.localDirty = true;
    saveState(state);
    const hot = path.startsWith("engine.") || path.startsWith("connection.") || path.startsWith("routing.") || path.startsWith("network.") || path.startsWith("router.");
    if (hot && state.vpn.connected && !path.startsWith("appearance")) {
      if (path === "engine.socksPort" || path === "engine.httpPort" || path === "connection.shareLan" || path.startsWith("engine.preference") || path.startsWith("connection.mux") || path === "routing.fragment" || path === "engine.fakeIp" || path === "engine.domainStrategy") {
        await connect();
      }
    }
    if (path === "router.captive" && state.router.trips) broadcast({ type: "snapshot", state: snapshot() });
    return snapshot();
  }

  function deviceSet(body) {
    const device = ensureDevice(body);
    if (body.excluded != null) device.excluded = Boolean(body.excluded);
    if (body.route) device.route = body.route;
    if (body.configId) device.configId = body.configId;
    if (Array.isArray(body.bypass)) device.bypass = body.bypass;
    if (body.online != null) device.online = Boolean(body.online);
    saveState(state);
    return snapshot();
  }

  function ensureDevice(body) {
    let device = state.devices.find((d) => d.id === body.id || (body.ip && d.ip === body.ip));
    if (!device && body.ip) {
      device = {
        id: randomUUID().slice(0, 8),
        name: body.name || body.ip,
        ip: body.ip,
        mac: body.mac || randomMac(),
        online: true,
        isNew: true,
        excluded: false,
        route: "default",
        bypass: [],
        traffic: { session: 0, today: 0, d7: 0, d30: 0 },
        demo: false,
      };
      state.devices.push(device);
    }
    if (!device) throw new Error("Устройство не найдено");
    return device;
  }

  function deviceRename(id, name) {
    const device = state.devices.find((d) => d.id === id);
    if (!device) throw new Error("Устройство не найдено");
    device.name = String(name || "").slice(0, 64) || device.name;
    saveState(state);
    return snapshot();
  }

  function addRule(body) {
    state.routing.custom.push({
      id: randomUUID().slice(0, 8),
      action: body.action || "direct",
      note: body.note || "",
      conditions: body.conditions || [],
    });
    if (state.routing.source === "local") state.routing.localDirty = true;
    saveState(state);
    return snapshot();
  }

  function saveBalancer(body) {
    const item = {
      id: body.id || randomUUID().slice(0, 8),
      name: body.name || "Балансировщик",
      servers: body.servers || [],
    };
    const idx = state.routing.balancers.findIndex((b) => b.id === item.id);
    if (idx >= 0) state.routing.balancers[idx] = item;
    else state.routing.balancers.push(item);
    saveState(state);
    return snapshot();
  }

  async function refreshSubscription(id) {
    const sub = state.subscriptions.find((s) => s.id === id);
    if (!sub) throw new Error("Подписка не найдена");
    if (!sub.url) {
      ctx.hooks.log("info", `«${sub.name}» без ссылки, список альфы оставлен`);
      return snapshot();
    }
    const response = await fetch(sub.url, { signal: AbortSignal.timeout(12000), headers: { "User-Agent": "stealthsurf-alfa" } });
    if (!response.ok) throw new Error(`Подписка ответила ${response.status}`);
    const nodes = parseSubscriptionBody(await response.text());
    if (!nodes.length) throw new Error("В подписке не нашлось конфигов");
    const previous = new Map((sub.nodes || []).filter((item) => item.protocol !== "direct").map((item) => [nodeIdentity(item), item.id]));
    for (const node of nodes) {
      const prev = previous.get(nodeIdentity(node));
      if (prev) node.id = prev;
    }
    const alive = new Set(nodes.map((node) => node.id));
    if (state.vpn.selectedId && !alive.has(state.vpn.selectedId) && state.vpn.selectedId !== "direct") {
      const same = nodes.find((node) => node.id === state.vpn.selectedId);
      if (!same) ctx.hooks.log("info", "Выбранный конфиг пропал из подписки");
    }
    sub.nodes = [...nodes, directNode()];
    sub.updatedAt = Date.now();
    ctx.hooks.log("info", `Подписка «${sub.name}»: ${nodes.length} конфигов`);
    saveState(state, true);
    return snapshot();
  }

  async function addSubscription(body) {
    const name = String(body.name || "Подписка").slice(0, 80);
    const url = String(body.url || "").trim();
    if (!url) throw new Error("Нужна ссылка или строка конфига");
    if (!/^https?:\/\//i.test(url)) {
      const node = parseShareLink(url);
      if (!node) throw new Error("Не похоже на ссылку подписки или vless/trojan/ss");
      const sub = { id: randomUUID().slice(0, 8), name, url: "", nodes: [node, directNode()] };
      state.subscriptions.push(sub);
      state.activeSubscription = sub.id;
      saveState(state, true);
      return snapshot();
    }
    const sub = { id: randomUUID().slice(0, 8), name, url, nodes: [directNode()] };
    state.subscriptions.push(sub);
    state.activeSubscription = sub.id;
    saveState(state);
    return refreshSubscription(sub.id);
  }

  function removeSubscription(id) {
    if (id === "main") throw new Error("Основную подписку альфы нельзя удалить");
    state.subscriptions = state.subscriptions.filter((s) => s.id !== id);
    if (state.activeSubscription === id) state.activeSubscription = "main";
    saveState(state);
    return snapshot();
  }

  async function pingOne(id) {
    const { node } = findNode(state, id || state.vpn.selectedId);
    if (!node) throw new Error("Конфиг не найден");
    if (node.protocol === "direct") {
      state.pings[node.id] = { ms: 0, at: Date.now() };
      return { id: node.id, ms: 0 };
    }
    const ms = await tcpPing(node.probeHost || node.host, node.probePort || node.port || 443, 1800);
    state.pings[node.id] = { ms, at: Date.now(), host: node.alpha ? "probe" : node.host };
    saveState(state);
    return { id: node.id, ms };
  }

  async function pingAll() {
    const results = [];
    for (const node of visibleNodes(state)) results.push(await pingOne(node.id));
    return { results, state: snapshot() };
  }

  async function zapretRecheck(all) {
    state.network.zapret.checking = true;
    saveState(state);
    const targets = [];
    if (state.network.youtubeZapret) targets.push(["youtube", "www.youtube.com", 443]);
    if (state.network.discordZapret) targets.push(["discord", "discord.com", 443]);
    for (const list of state.network.zapret.lists) {
      const host = (list.domains || [])[0];
      if (host) targets.push([list.id, host, 443]);
    }
    if (all && !targets.length) targets.push(["youtube", "www.youtube.com", 443], ["discord", "discord.com", 443]);
    for (const [id, host, port] of targets) {
      const ms = await tcpPing(host, port, 2500);
      state.network.zapret.serviceWays[id] = ms == null ? "vpn" : "direct";
    }
    state.network.zapret.lastCheck = Date.now();
    state.network.zapret.checking = false;
    ctx.hooks.log("info", all ? "Проверка способов завершена, сервисы возвращены из запасного VPN" : "Рабочие прямые пути подтверждены");
    if (state.vpn.connected) await connect();
    else saveState(state);
    return snapshot();
  }

  function zapretList(body) {
    if (body.remove) {
      state.network.zapret.lists = state.network.zapret.lists.filter((l) => l.id !== body.id);
    } else {
      state.network.zapret.lists.push({
        id: randomUUID().slice(0, 8),
        name: body.name || "Список",
        domains: String(body.domains || "").split(/[\s,]+/).filter(Boolean),
        enabled: true,
        methodId: body.methodId || "",
      });
    }
    saveState(state);
    return snapshot();
  }

  function zapretMethod(body) {
    state.network.zapret.methods.push({
      id: randomUUID().slice(0, 8),
      name: body.name || "Способ",
      kind: body.kind || "direct",
      note: "В альфе способ хранится и выбирает прямой путь или запасной VPN. Подмена пакетов на этом стенде не выполняется.",
    });
    saveState(state);
    return snapshot();
  }

  async function runAutomode() {
    if (!state.automode.enabled) throw new Error("Авторежим выключен");
    const pool = visibleNodes(state).filter((n) => n.protocol !== "direct" && (!state.automode.configId || n.id === state.automode.configId || n.group === state.automode.configId));
    state.automode.log = [];
    for (const node of pool) {
      const engine = pickEngine(state.engine.preference, node.protocol);
      const ms = node.host ? await tcpPing(node.probeHost || node.host, node.probePort || node.port || 443, 1500) : null;
      state.automode.log.push({ id: node.id, name: node.name, engine, ms, at: Date.now() });
      if (ms != null) {
        state.automode.log.at(-1).picked = true;
        saveState(state);
        await selectNode(node.id, { force: true });
        return snapshot();
      }
    }
    saveState(state);
    throw new Error("Авторежим не нашёл отвечающий сервер");
  }

  async function applyNetAuto() {
    const rule = state.netAuto.rules[state.netAuto.current] || state.netAuto.rules.default;
    if (!rule) return;
    if (rule === "direct") await selectNode("direct", { force: true });
    else await selectNode(rule, { force: true });
  }

  async function speedTest() {
    const direct = await measureDirect();
    let vpn = null;
    if (state.vpn.connected && live.edge) vpn = await measureViaProxy();
    const cpu = live.load.cpu;
    return { direct, vpn, cpu, at: Date.now() };
  }

  async function measureDirect() {
    const ping = await tcpPing("1.1.1.1", 443, 2000);
    const started = Date.now();
    try {
      const response = await fetch("https://example.com", { signal: AbortSignal.timeout(8000) });
      const buf = Buffer.from(await response.arrayBuffer());
      const ms = Date.now() - started;
      return { ping, ms, bytes: buf.length, down: Math.round(buf.length / Math.max(ms, 1) * 1000) };
    } catch (error) {
      return { ping, error: error.message };
    }
  }

  async function measureViaProxy() {
    const started = Date.now();
    try {
      const body = await proxyFetch("https://example.com/");
      const ms = Date.now() - started;
      return { ms, bytes: body.length, down: Math.round(body.length / Math.max(ms, 1) * 1000) };
    } catch (error) {
      return { error: error.message };
    }
  }

  async function leakTest() {
    const result = { dns: [], ipv6: state.router.ipv6, via: [] };
    try {
      const looked = await dnsLookup("example.com");
      result.dns = looked;
    } catch (error) {
      result.dnsError = error.message;
    }
    if (live.dns) {
      result.localDns = await queryLocalDns("example.com").catch((error) => error.message);
    }
    result.note = state.router.ipv6 === "block"
      ? "IPv6 клиентов режется политикой."
      : "IPv6 клиентов не блокируется.";
    return result;
  }

  function resetNetwork() {
    state.diagnostics.mtu = 1500;
    state.connection.ipv4Only = false;
    state.router.ipv6 = "block";
    state.diagnostics.logLevel = "warning";
    state.engine.socksPort = 20808;
    state.engine.httpPort = 20809;
    state.connection.shareLan = false;
    state.engine.fakeIp = false;
    ctx.hooks.log("info", "Сетевые настройки возвращены к значениям альфы");
    saveState(state);
    return snapshot();
  }

  async function fetchCore(id) {
    const result = await downloadCore(id, (line) => ctx.hooks.log("info", line));
    state.engine.cores[id] = { version: result.version, note: result.tag, bytes: result.bytes, at: Date.now() };
    saveState(state, true);
    ctx.hooks.log("info", `${ENGINES[id].title} ${result.version} скачан`);
    return { ok: true, ...result, cores: coreStatus(state) };
  }

  async function removeCore(id) {
    if (live.engineId === id && engineRunning()) throw new Error("Это ядро сейчас запущено");
    const file = join(DATA, "cores", ENGINES[id].bin);
    if (existsSync(file)) rmSync(file, { force: true });
    delete state.engine.cores[id];
    saveState(state);
    return { ok: true, cores: coreStatus(state) };
  }

  async function updateGeo(customUrl) {
    mkdirSync(GEO_DIR, { recursive: true });
    const base = state.engine.geoSource === "custom" && (customUrl || state.engine.geoUrl)
      ? (customUrl || state.engine.geoUrl).replace(/\/$/, "")
      : "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download";
    const files = state.engine.geoSource === "custom" && customUrl && !customUrl.endsWith("/")
      ? [customUrl]
      : [`${base}/geosite.dat`, `${base}/geoip.dat`];
    let geosite = state.engine.geo.geosite;
    let geoip = state.engine.geo.geoip;
    for (const url of files) {
      const name = url.split("/").pop().split("?")[0] || "geo.dat";
      const response = await fetch(url, { signal: AbortSignal.timeout(30000), headers: { "User-Agent": "stealthsurf-alfa" } });
      if (!response.ok) throw new Error(`${name}: ${response.status}`);
      const buf = Buffer.from(await response.arrayBuffer());
      writeFileSync(join(GEO_DIR, name), buf);
      if (name.includes("geosite")) geosite = buf.length;
      if (name.includes("geoip")) geoip = buf.length;
    }
    state.engine.geo = { geosite, geoip, updatedAt: Date.now() };
    saveState(state, true);
    return state.engine.geo;
  }

  function saveFeedback(body) {
    const text = String(body.text || "").slice(0, 4000);
    if (!text.trim()) throw new Error("Напишите текст");
    const files = Array.isArray(body.files) ? body.files.slice(0, 5) : [];
    const dir = join(DATA, "feedback");
    mkdirSync(dir, { recursive: true });
    const id = randomUUID().slice(0, 8);
    const stored = [];
    for (const file of files) {
      const buf = Buffer.from(String(file.data || ""), "base64");
      if (buf.length > 10 * 1024 * 1024) throw new Error("Файл больше 10 МБ");
      const safe = `${id}-${String(file.name || "file").replace(/[^\w.\-]+/g, "_")}`.slice(0, 80);
      writeFileSync(join(dir, safe), buf);
      stored.push({ name: file.name, size: buf.length });
    }
    state.feedback.unshift({ id, text, files: stored, at: Date.now() });
    state.feedback = state.feedback.slice(0, 50);
    saveState(state, true);
    return { ok: true, id };
  }

  function setPassword(body) {
    if (OPEN_PANEL) throw new Error("В этой сборке вход без пароля — смена не нужна");
    if (!checkPassword(body.oldPassword || "", state.password)) throw new Error("Текущий пароль не подошёл");
    if (!body.password || String(body.password).length < 4) throw new Error("Новый пароль короче 4 символов");
    state.password = hashPassword(body.password);
    state.sessions = {};
    saveState(state, true);
    return { ok: true, relogin: true };
  }

  function makePair() {
    const code = randomBytes(3).toString("hex");
    live.pairCodes.set(code, Date.now() + 5 * 60 * 1000);
    return { code, ttl: 300 };
  }

  function exportSettings() {
    const copy = publicState(state, {});
    delete copy.logs;
    delete copy.runtime;
    return { filename: "stealthsurf-alfa.json", settings: copy };
  }

  function importSettings(incoming) {
    const settings = incoming.settings || incoming;
    for (const key of ["router", "routing", "network", "connection", "automode", "netAuto", "engine", "appearance", "other", "updates", "diagnostics", "devices", "subscriptions"]) {
      if (settings[key]) state[key] = settings[key];
    }
    saveState(state, true);
    ctx.hooks.log("info", "Настройки загружены из файла");
    return snapshot();
  }

  function readConfigs() {
    const dir = join(DATA, "run");
    const out = {};
    for (const name of ["xray.full.json", "ferrum.full.json", "sing-box.full.json", "mihomo.full.yaml"]) {
      const file = join(dir, name);
      if (existsSync(file)) out[name] = readText(file);
    }
    return out;
  }

  async function publishHa(force = false) {
    if (!state.router.ha && !force) return { ok: false };
    const mqtt = state.router.mqtt;
    if (!mqtt.host) throw new Error("Брокер MQTT не задан");
    const payload = JSON.stringify({ connected: state.vpn.connected, engine: live.engineId, ip: state.vpn.exitIp || live.publicIp });
    await mqttPublish(mqtt, "stealthsurf/vpn", payload);
    mqtt.status = "опубликовано";
    saveState(state);
    return { ok: true };
  }

  function wake(macOrId) {
    const device = state.devices.find((d) => d.id === macOrId || d.mac === macOrId);
    const mac = device?.mac || macOrId;
    if (!/^([0-9a-f]{2}:){5}[0-9a-f]{2}$/i.test(mac || "")) throw new Error("Нужен MAC-адрес");
    const bytes = Buffer.alloc(6 + 16 * 6);
    bytes.fill(0xff, 0, 6);
    const macBytes = Buffer.from(mac.split(":").map((p) => parseInt(p, 16)));
    for (let i = 0; i < 16; i++) macBytes.copy(bytes, 6 + i * 6);
    const socket = dgram.createSocket("udp4");
    return new Promise((resolve, reject) => {
      socket.on("error", reject);
      socket.bind(() => {
        socket.setBroadcast(true);
        socket.send(bytes, 9, "255.255.255.255", () => {
          socket.close();
          ctx.hooks.log("info", `Wake-on-LAN отправлен на ${mac}`);
          resolve({ ok: true, mac });
        });
      });
    });
  }

  function issueSession() {
    const token = randomBytes(24).toString("hex");
    state.sessions[token] = { exp: Date.now() + 14 * 864e5 };
    saveState(state, true);
    return token;
  }

  /** Открытый доступ: сессия без пароля (альфа на LAN). */
  function openSession() {
    state.failedLogins = 0;
    state.lockedUntil = 0;
    return issueSession();
  }

  function login(password, pairCode) {
    if (OPEN_PANEL) return openSession();
    if (state.lockedUntil && Date.now() < state.lockedUntil) {
      throw Object.assign(new Error("Слишком много попыток, подождите минуту"), { status: 429 });
    }
    const code = String(pairCode || "").trim().toLowerCase();
    if (code && live.pairCodes.get(code) > Date.now()) {
      live.pairCodes.delete(code);
      return issueSession();
    }
    const pass = String(password || "").trim();
    if (!pass) {
      throw Object.assign(new Error("Введите пароль"), { status: 401 });
    }
    if (!state.password?.salt || !state.password?.hash) {
      state.password = hashPassword(DEFAULT_PANEL_PASSWORD);
      saveState(state, true);
    }
    if (!checkPassword(pass, state.password)) {
      state.failedLogins += 1;
      if (state.failedLogins >= 8) {
        state.lockedUntil = Date.now() + 60_000;
        state.failedLogins = 0;
      }
      saveState(state);
      throw Object.assign(new Error("Неверный пароль. Сброс: /jffs/scripts/alfa reset-password"), { status: 401 });
    }
    if (passwordNeedsUpgrade(state.password)) {
      state.password = hashPassword(pass);
    }
    state.failedLogins = 0;
    state.lockedUntil = 0;
    return issueSession();
  }

  function sessionOk(token) {
    const row = token && state.sessions[token];
    if (!row) return false;
    if (row.exp < Date.now()) {
      delete state.sessions[token];
      return false;
    }
    return true;
  }

  function logout(token) {
    if (OPEN_PANEL) return;
    if (token) delete state.sessions[token];
    saveState(state);
  }

  return {
    state,
    live,
    boot,
    shutdown,
    login,
    logout,
    openSession,
    sessionOk,
    openPanel: OPEN_PANEL,
    invoke,
    snapshot,
    broadcast,
    ctx,
  };
}

function emptyBytes() {
  return { vpnDown: 0, vpnUp: 0, directDown: 0, directUp: 0 };
}

function sum(list) {
  return list.reduce((a, b) => a + b, 0);
}

function normalizeClient(ip) {
  return String(ip || "").replace(/^::ffff:/, "");
}

function randomMac() {
  const bytes = randomBytes(6);
  bytes[0] = (bytes[0] | 2) & 0xfe;
  return Array.from(bytes).map((b) => b.toString(16).padStart(2, "0")).join(":");
}

function directNode() {
  return { id: "direct", name: "Без VPN", protocol: "direct", country: "", flag: "direct", until: "", online: true, alpha: true };
}

function engineReason(state, node, engineId) {
  if (state.engine.preference === "auto") {
    return `Авто выбрал ${ENGINES[engineId].title}: ${ENGINES[engineId].routing}`;
  }
  return `Явный движок ${ENGINES[engineId].title}. ${ENGINES[engineId].routing}`;
}

export function tcpPing(host, port, timeout) {
  if (!host) return Promise.resolve(null);
  return new Promise((resolve) => {
    const started = Date.now();
    const socket = net.connect({ host, port: Number(port) || 443 });
    const done = (value) => { socket.destroy(); resolve(value); };
    socket.setTimeout(timeout, () => done(null));
    socket.once("connect", () => done(Date.now() - started));
    socket.once("error", () => done(null));
  });
}

async function detectNetwork() {
  try {
    const { stdout } = await exec("ip", ["route", "show", "default"]);
    if (/wwan|usb|lte|modem/i.test(stdout)) return "lte";
    return "ethernet";
  } catch {
    return "ethernet";
  }
}

function dnsLookup(host) {
  return new Promise((resolve, reject) => {
    net.lookup(host, { all: true }, (error, addresses) => {
      if (error) reject(error);
      else resolve(addresses);
    });
  });
}

function queryLocalDns(host) {
  const id = 0x1234;
  const labels = host.split(".").flatMap((part) => [Buffer.from([part.length]), Buffer.from(part)]);
  const packet = Buffer.concat([
    Buffer.from([0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
    ...labels,
    Buffer.from([0, 0, 1, 0, 1]),
  ]);
  void id;
  return new Promise((resolve, reject) => {
    const socket = dgram.createSocket("udp4");
    const timer = setTimeout(() => { socket.close(); reject(new Error("DNS альфы молчит")); }, 2000);
    socket.on("message", (msg) => {
      clearTimeout(timer);
      socket.close();
      resolve({ bytes: msg.length, answers: msg.readUInt16BE(6) });
    });
    socket.send(packet, 5353, "127.0.0.1");
  });
}

function mqttPublish(mqtt, topic, payload) {
  const host = mqtt.host;
  const port = Number(mqtt.port || 1883);
  const clientId = "alfa";
  return new Promise((resolve, reject) => {
    const socket = net.connect({ host, port });
    const timer = setTimeout(() => { socket.destroy(); reject(new Error("MQTT не ответил")); }, 4000);
    socket.once("error", (error) => { clearTimeout(timer); reject(error); });
    socket.once("connect", () => {
      const id = Buffer.from(clientId);
      const user = Buffer.from(mqtt.username || "");
      const pass = Buffer.from(mqtt.password || "");
      const flags = mqtt.username ? 0xc2 : 0x02;
      const vh = Buffer.concat([
        Buffer.from([0, 4]), Buffer.from("MQTT"), Buffer.from([4, flags, 0, 60]),
        Buffer.from([0, id.length]), id,
        ...(mqtt.username ? [Buffer.from([0, user.length]), user, Buffer.from([0, pass.length]), pass] : []),
      ]);
      socket.write(mqttPacket(1, vh));
    });
    socket.once("data", (buf) => {
      if (buf[0] >> 4 !== 2 || buf[3] !== 0) {
        clearTimeout(timer);
        socket.destroy();
        reject(new Error("MQTT отклонил вход"));
        return;
      }
      const t = Buffer.from(topic);
      const p = Buffer.from(payload);
      const body = Buffer.concat([Buffer.from([0, t.length]), t, p]);
      socket.write(mqttPacket(3, body));
      setTimeout(() => { clearTimeout(timer); socket.end(); resolve(true); }, 50);
    });
  });
}

function mqttPacket(type, body) {
  const head = Buffer.from([type << 4]);
  const len = encodeRemaining(body.length);
  return Buffer.concat([head, len, body]);
}

function encodeRemaining(n) {
  const out = [];
  do {
    let byte = n % 128;
    n = Math.floor(n / 128);
    if (n > 0) byte |= 0x80;
    out.push(byte);
  } while (n > 0);
  return Buffer.from(out);
}

function readText(file) {
  if (statSync(file).size > 400_000) return "файл слишком большой для панели";
  return readFileSync(file, "utf8");
}
