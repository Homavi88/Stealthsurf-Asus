/**
 * EngVPN panel extensions mixed into the vendored alfa runtime at build time.
 * Open components only — shells out to engvpnd / transparent / dpi / warp / update.
 * StealthSurf HTTP API (user-provided API keys) + local subscription URLs.
 */
import { execFile, execFileSync } from "node:child_process";
// execFileSync used by sampleRouterTraffic (iptables /proc tick)
import { promisify } from "node:util";
import { existsSync, readFileSync, writeFileSync, mkdirSync, unlinkSync, mkdtempSync, rmSync } from "node:fs";
import { join, dirname } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { hostname, totalmem, freemem, arch, platform, cpus, loadavg } from "node:os";
import { randomUUID } from "node:crypto";

const exec = promisify(execFile);
const LIB = dirname(fileURLToPath(import.meta.url));
const RUNTIME_ROOT = join(LIB, "..");
const SHARE = join(RUNTIME_ROOT, "..");
const ENGVPN_PREFIX = join(SHARE, "..", "..");
const ENGVPND = join(ENGVPN_PREFIX, "sbin", "engvpnd");
const DATA = process.env.ENGVPN_DATA_DIR || join(ENGVPN_PREFIX, "data");
const ACCOUNT_PATH = join(DATA, "account.json");
const SS_API = process.env.ENGVPN_SS_API || "https://api.stealthsurf.net";
const API_KEY_RE = /^stlth_([a-f0-9]{8})_([a-f0-9]{24})$/;

async function shEngvpnd(...args) {
  const bin = existsSync(ENGVPND) ? ENGVPND : "engvpnd";
  const { stdout, stderr } = await exec(bin, args, {
    env: { ...process.env, ENGVPN_DATA_DIR: process.env.ENGVPN_DATA_DIR || DATA },
    timeout: 180000,
  });
  return { stdout: String(stdout || ""), stderr: String(stderr || "") };
}

async function shScript(name, ...args) {
  const script = join(SHARE, name);
  if (!existsSync(script)) throw new Error(`нет ${name}`);
  const { stdout, stderr } = await exec("sh", [script, ...args], {
    env: { ...process.env, ENGVPN_DATA_DIR: process.env.ENGVPN_DATA_DIR || DATA },
    timeout: 180000,
  });
  return { stdout: String(stdout || ""), stderr: String(stderr || "") };
}

export function writeTransparentConf(partial = {}) {
  mkdirSync(DATA, { recursive: true });
  const path = join(DATA, "transparent.conf");
  const cur = {};
  if (existsSync(path)) {
    for (const line of readFileSync(path, "utf8").split("\n")) {
      const m = line.match(/^([a-z_]+)=(.*)$/);
      if (m) cur[m[1]] = m[2];
    }
  }
  const next = {
    mode: "off",
    method: "redirect",
    port: "12345",
    mark: "0x39000",
    table: "79",
    killswitch: "0",
    lan_if: "br0",
    lan_cidr: "",
    dns_hijack: "0",
    dns_port: "5353",
    captive_open: "0",
    ...cur,
    ...partial,
  };
  writeFileSync(path, `${Object.entries(next).map(([k, v]) => `${k}=${v}`).join("\n")}\n`, { mode: 0o600 });
  return next;
}

export function modeFromRouter(routerMode) {
  switch (String(routerMode || "")) {
    case "all":
    case "vpn":
    case "full":
      return "all";
    case "selected":
    case "only":
    case "include":
      return "selected";
    case "except":
    case "exclude":
      return "exclude";
    case "off":
    case "direct":
    case "disabled":
      return "off";
    default:
      return "off";
  }
}

export function routerModeFromTransparent(mode) {
  switch (String(mode || "")) {
    case "all":
      return "all";
    case "selected":
    case "include":
      return "selected";
    case "exclude":
    case "except":
      return "except";
    default:
      return "off";
  }
}

export function readTransparentConf() {
  const path = join(DATA, "transparent.conf");
  const cur = {};
  if (!existsSync(path)) return cur;
  for (const line of readFileSync(path, "utf8").split("\n")) {
    const m = line.match(/^([a-z_]+)=(.*)$/);
    if (m) cur[m[1]] = m[2];
  }
  return cur;
}

/**
 * Write data/devices.select from panel device checkboxes (excluded=true).
 * transparent.sh reads this file for selected/exclude modes (IP or MAC per line).
 */
export function syncDevicesSelect(state) {
  mkdirSync(DATA, { recursive: true });
  const lines = [];
  for (const d of state?.devices || []) {
    if (!d?.excluded) continue;
    if (d.ip) lines.push(String(d.ip).trim());
    if (d.mac) lines.push(String(d.mac).trim());
  }
  const uniq = [...new Set(lines.filter(Boolean))];
  writeFileSync(join(DATA, "devices.select"), uniq.length ? `${uniq.join("\n")}\n` : "", { mode: 0o600 });
  return uniq;
}

/** Collect IP/MAC identifiers for devices marked excluded in the UI. */
export function selectedDeviceIds(state) {
  const out = [];
  for (const d of state?.devices || []) {
    if (!d?.excluded) continue;
    if (d.ip) out.push(String(d.ip).trim());
    if (d.mac) out.push(String(d.mac).trim());
  }
  return [...new Set(out.filter(Boolean))];
}

/** Derive transparent.conf dns_hijack / captive_open from panel router toggles. */
export function transparentDnsFlags(state) {
  const r = state?.router || {};
  const wantDns = !!(r.dnsViaVpn || r.dnsLock || r.adblock);
  const captiveOpen = !!(r.trips && r.captive);
  return {
    dns_hijack: wantDns && !captiveOpen ? "1" : "0",
    dns_port: "5353",
    captive_open: captiveOpen ? "1" : "0",
  };
}

export async function engvpnTransparent(command, body = {}) {
  if (body && typeof body === "object") {
    const patch = {};
    if (body.mode) patch.mode = body.mode;
    if (body.method) patch.method = body.method;
    if (body.port) patch.port = String(body.port);
    if (body.killswitch != null) patch.killswitch = body.killswitch ? "1" : "0";
    if (body.dns_hijack != null) patch.dns_hijack = body.dns_hijack ? "1" : "0";
    if (body.dns_port != null) patch.dns_port = String(body.dns_port);
    if (body.captive_open != null) patch.captive_open = body.captive_open ? "1" : "0";
    if (body.routerMode) patch.mode = modeFromRouter(body.routerMode);
    if (body.transparentMode) patch.mode = modeFromRouter(body.transparentMode);
    if (Object.keys(patch).length) writeTransparentConf(patch);
    if (Array.isArray(body.devices)) {
      mkdirSync(DATA, { recursive: true });
      writeFileSync(join(DATA, "devices.select"), body.devices.length ? `${body.devices.join("\n")}\n` : "", { mode: 0o600 });
    }
  }
  const { stdout } = await shEngvpnd("transparent", command || "status");
  return { ok: true, output: stdout.trim() };
}

/** Read/write data/updates.conf used by schedule-update.sh + Merlin cru. */
export function readUpdatesConf() {
  const path = join(DATA, "updates.conf");
  const out = {
    interval: "1d",
    auto: false,
    windowStart: 2,
    windowEnd: 5,
    geoWeekly: true,
    coresWhenMissing: true,
    lastCheck: null,
    lastResult: "",
  };
  if (!existsSync(path)) return out;
  for (const line of readFileSync(path, "utf8").split("\n")) {
    const m = line.match(/^([a-z_]+)=(.*)$/);
    if (!m) continue;
    const [, k, v] = m;
    if (k === "interval") out.interval = v || out.interval;
    else if (k === "auto") out.auto = v === "1";
    else if (k === "window_start") out.windowStart = Number(v) || out.windowStart;
    else if (k === "window_end") out.windowEnd = Number(v) || out.windowEnd;
    else if (k === "geo_weekly") out.geoWeekly = v === "1";
    else if (k === "cores_when_missing") out.coresWhenMissing = v === "1";
    else if (k === "last_check" && v) {
      const t = Date.parse(v);
      out.lastCheck = Number.isFinite(t) ? t : v;
    } else if (k === "last_result") out.lastResult = v;
  }
  return out;
}

export function writeUpdatesConf(partial = {}) {
  mkdirSync(DATA, { recursive: true });
  const cur = readUpdatesConf();
  const next = { ...cur, ...partial };
  const body = [
    `interval=${next.interval || "1d"}`,
    `auto=${next.auto ? "1" : "0"}`,
    `window_start=${next.windowStart ?? 2}`,
    `window_end=${next.windowEnd ?? 5}`,
    `geo_weekly=${next.geoWeekly !== false ? "1" : "0"}`,
    `cores_when_missing=${next.coresWhenMissing !== false ? "1" : "0"}`,
    `last_check=${next.lastCheck ? new Date(next.lastCheck).toISOString() : ""}`,
    `last_result=${next.lastResult || ""}`,
    "",
  ].join("\n");
  writeFileSync(join(DATA, "updates.conf"), body, { mode: 0o600 });
  return next;
}

/** Persist panel updates.* → updates.conf and (re)install Merlin cru / cron. */
export async function syncUpdatesSchedule(state) {
  const u = state?.updates || {};
  writeUpdatesConf({
    interval: u.interval || "1d",
    auto: !!u.auto,
    windowStart: u.windowStart ?? 2,
    windowEnd: u.windowEnd ?? 5,
    geoWeekly: u.geoWeekly !== false,
    coresWhenMissing: u.coresWhenMissing !== false,
    lastCheck: u.lastCheck || null,
    lastResult: u.lastResult || u.note || "",
  });
  const args = [
    "schedule-update",
    "write-conf",
    `interval=${u.interval || "1d"}`,
    `auto=${u.auto ? "1" : "0"}`,
    `window_start=${u.windowStart ?? 2}`,
    `window_end=${u.windowEnd ?? 5}`,
    `geo_weekly=${u.geoWeekly !== false ? "1" : "0"}`,
    `cores_when_missing=${u.coresWhenMissing !== false ? "1" : "0"}`,
  ];
  try {
    await shEngvpnd(...args);
    return { ok: true };
  } catch (e1) {
    // Hosts without engvpnd wrapper: try script directly (write-conf also installs cru).
    try {
      await shScript(
        "schedule-update.sh",
        "write-conf",
        `interval=${u.interval || "1d"}`,
        `auto=${u.auto ? "1" : "0"}`,
        `window_start=${u.windowStart ?? 2}`,
        `window_end=${u.windowEnd ?? 5}`,
        `geo_weekly=${u.geoWeekly !== false ? "1" : "0"}`,
        `cores_when_missing=${u.coresWhenMissing !== false ? "1" : "0"}`,
      );
      return { ok: true };
    } catch (e2) {
      const error = String(e2.message || e2 || e1.message || e1);
      return { ok: false, error };
    }
  }
}

export async function engvpnUpdateCheck(state) {
  const { stdout } = await shEngvpnd("update-check");
  const out = {};
  for (const line of stdout.split("\n")) {
    const i = line.indexOf("=");
    if (i > 0) out[line.slice(0, i)] = line.slice(i + 1);
  }
  const now = Date.now();
  const available = out.update === "1" || out.available === "1" || out.update_available === "1";
  const feedVer = out.feed || out.latest || "";
  if (state?.updates) {
    state.updates.lastCheck = now;
    if (feedVer) state.updates.latest = feedVer;
    state.updates.available = available;
    state.updates.lastResult = available ? `available:${feedVer}` : `up-to-date:${feedVer}`;
  }
  try {
    writeUpdatesConf({
      ...(state?.updates
        ? {
            interval: state.updates.interval,
            auto: !!state.updates.auto,
            windowStart: state.updates.windowStart,
            windowEnd: state.updates.windowEnd,
            geoWeekly: state.updates.geoWeekly,
            coresWhenMissing: state.updates.coresWhenMissing,
          }
        : {}),
      lastCheck: now,
      lastResult: state?.updates?.lastResult || "",
    });
  } catch {
    /* ignore */
  }
  if (!out.message) {
    const parts = [];
    if (out.current || out.version || out.installed) parts.push(`текущая ${out.current || out.version || out.installed}`);
    if (feedVer) parts.push(`в feed ${feedVer}`);
    if (available) parts.push("доступно обновление");
    out.message = parts.length ? parts.join(" · ") : "Проверка feed EngVPN завершена";
  }
  out.ok = true;
  out.available = available;
  out.update_available = available ? "1" : "0";
  out.latest = feedVer || out.latest;
  out.version = feedVer || out.version;
  out.lastCheck = now;
  return out;
}

/** Apply feed package via engvpnd update (SHA-256 + Minisign). */
export async function engvpnUpdateApply(state, body = {}) {
  const wait = String(body.wait || body.timeout || "90");
  let stdout = "";
  let stderr = "";
  try {
    const res = await shEngvpnd("update", wait);
    stdout = res.stdout || "";
    stderr = res.stderr || "";
  } catch (e) {
    stdout = String(e?.stdout || "");
    stderr = String(e?.stderr || e?.message || e);
    const err = new Error(stderr.trim() || stdout.trim() || "Не удалось установить обновление");
    err.status = 500;
    throw err;
  }
  const combined = `${stdout}\n${stderr}`;
  if (state?.updates) {
    state.updates.available = false;
    state.updates.lastResult = `applied:${state.updates.latest || ""}`;
    state.updates.lastCheck = Date.now();
    try {
      writeUpdatesConf({
        interval: state.updates.interval,
        auto: !!state.updates.auto,
        windowStart: state.updates.windowStart,
        windowEnd: state.updates.windowEnd,
        geoWeekly: state.updates.geoWeekly,
        coresWhenMissing: state.updates.coresWhenMissing,
        lastCheck: state.updates.lastCheck,
        lastResult: state.updates.lastResult,
      });
    } catch {
      /* ignore */
    }
  }
  return {
    ok: true,
    output: combined.trim(),
    message: /already on|уже/i.test(combined)
      ? "Уже актуальная версия"
      : "Обновление установлено — перезагрузите панель при необходимости",
  };
}

export async function engvpnScheduleUpdate(command = "status", ...extra) {
  const args = [command || "status", ...extra.filter((x) => x != null && x !== "")];
  const { stdout } = await shEngvpnd("schedule-update", ...args);
  return { ok: true, output: stdout.trim() };
}

export async function engvpnReconnect() {
  const { stdout } = await shEngvpnd("reconnect");
  return { ok: true, output: stdout.trim() };
}

export async function engvpnWatchdog() {
  const { stdout } = await shEngvpnd("watchdog");
  return { ok: true, output: stdout.trim() };
}

/**
 * Router-side privacy / stealth checks (exit IP, DNS, IPv6, kill-switch, DPI fingerprint).
 * Prefer engvpnd privacy → privacy-check.sh; enrich with panel VPN context.
 */
export async function engvpnPrivacyCheck(state = {}, opts = {}) {
  const conf = readTransparentConf();
  const dpi = readDpiStatus();
  let proto = "";
  let security = "";
  let engine = state?.engine?.preference || state?.engine?.active || "";
  const selectedId = state?.vpn?.selectedId;
  if (selectedId && Array.isArray(state?.subscriptions)) {
    for (const sub of state.subscriptions) {
      const node = (sub.nodes || []).find((n) => n.id === selectedId);
      if (node) {
        proto = node.protocol || node.type || "";
        security = node.security || node.tls || node.reality || "";
        if (typeof node.connection_url === "string") {
          const m = node.connection_url.match(/^([a-z0-9+]+):/i);
          if (m && !proto) proto = m[1];
          if (/reality/i.test(node.connection_url)) security = security || "reality";
        }
        break;
      }
    }
  }

  const env = {
    ...process.env,
    ENGVPN_DATA_DIR: process.env.ENGVPN_DATA_DIR || DATA,
    ENGVPN_VPN_CONNECTED: state?.vpn?.connected ? "1" : "0",
    ENGVPN_IPV6_POLICY: state?.router?.ipv6 || "block",
    ENGVPN_DNS_VIA_VPN: state?.router?.dnsViaVpn ? "1" : "0",
    ENGVPN_PROTO_HINT: String(proto || ""),
    ENGVPN_SECURITY_HINT: String(security || ""),
    ENGVPN_ENGINE_HINT: String(engine || ""),
    ENGVPN_HTTP_PORT: opts.httpPort != null ? String(opts.httpPort) : process.env.ENGVPN_HTTP_PORT || "",
    ENGVPN_SOCKS_PORT: opts.socksPort != null ? String(opts.socksPort) : process.env.ENGVPN_SOCKS_PORT || String(state?.engine?.socksPort || ""),
  };

  let report;
  try {
    const script = join(SHARE, "privacy-check.sh");
    const args = [script, opts.action || "all"];
    const { stdout } = await exec("sh", args, { env, timeout: 90000 });
    const text = String(stdout || "").trim();
    const start = text.indexOf("{");
    const jsonText = start >= 0 ? text.slice(start) : text;
    report = JSON.parse(jsonText);
  } catch (e) {
    report = {
      ok: false,
      error: e.message || String(e),
      disclaimer: "Не удалось выполнить privacy-check.sh",
      kind: "error",
    };
  }

  // Panel-known IPs as fallback when curl from shell had no proxy ports
  if (report && report.exit) {
    if (!report.exit.tunnel_ip && state?.runtime?.exitIp) report.exit.tunnel_ip = state.runtime.exitIp;
    if (!report.exit.wan_ip && state?.runtime?.publicIp) report.exit.wan_ip = state.runtime.publicIp;
    if (report.exit.tunnel_ip && report.exit.wan_ip) {
      report.exit.ok = report.exit.tunnel_ip !== report.exit.wan_ip;
      report.exit.leak = report.exit.tunnel_ip === report.exit.wan_ip && !!state?.vpn?.connected;
    }
  }

  // Surface DPI from Node when shell smoke-skipped NFQUEUE
  if (report && report.dpi) {
    report.dpi.enabled = report.dpi.enabled || !!dpi.enabled;
    report.dpi.panel = dpi;
  }
  if (report && report.transparent && conf) {
    report.transparent.mode = report.transparent.mode || conf.mode || "off";
    report.transparent.method = report.transparent.method || conf.method || "redirect";
    report.transparent.killswitch_conf = conf.killswitch === "1";
  }

  report.ui = {
    title: "Проверки скрытности",
    labels: {
      exit: "Выходной IP",
      dns: "DNS",
      ipv6: "IPv6",
      killswitch: "Kill-switch",
      dpi: "DPI / отпечаток",
      webrtc: "WebRTC (клиент)",
      path: "Путь / MTU / UDP",
    },
  };
  return report;
}

export async function engvpnDpi(command = "status", body = {}) {
  if (body && typeof body === "object") {
    mkdirSync(DATA, { recursive: true });
    const path = join(DATA, "dpi.conf");
    const cur = {};
    if (existsSync(path)) {
      for (const line of readFileSync(path, "utf8").split("\n")) {
        const m = line.match(/^([a-z_]+)=(.*)$/);
        if (m) cur[m[1]] = m[2];
      }
    }
    const next = {
      enabled: cur.enabled || "0",
      queue: cur.queue || "390",
      youtube: cur.youtube || "1",
      discord: cur.discord || "1",
      mode: cur.mode || "nfqws",
      ...cur,
    };
    if (body.enabled != null) next.enabled = body.enabled ? "1" : "0";
    if (body.youtube != null) next.youtube = body.youtube ? "1" : "0";
    if (body.discord != null) next.discord = body.discord ? "1" : "0";
    if (body.queue != null) next.queue = String(body.queue);
    writeFileSync(path, `${Object.entries(next).map(([k, v]) => `${k}=${v}`).join("\n")}\n`, { mode: 0o600 });
  }
  const { stdout } = await shEngvpnd("dpi", command);
  return { ok: true, output: stdout.trim() };
}

export async function engvpnWarp(command = "status", body = {}) {
  if (command === "create" || command === "warpCreate") {
    const { stdout } = await shEngvpnd("warp", "create");
    return { ok: true, output: stdout.trim(), profile: join(DATA, "warp.profile.ini") };
  }
  if (command === "import" || command === "warpImport") {
    const text = String(body?.text || "");
    if (!text.trim()) throw new Error("Нужен WireGuard INI");
    mkdirSync(DATA, { recursive: true });
    const path = join(DATA, "warp.profile.ini");
    writeFileSync(path, text, { mode: 0o600 });
    const { stdout } = await shEngvpnd("warp", "import-file", path);
    return { ok: true, output: stdout.trim() };
  }
  if (command === "gre-up" || command === "gre-down") {
    try {
      const { stdout } = await shEngvpnd("warp", command);
      return { ok: true, output: stdout.trim() };
    } catch (e) {
      const error = String(e.message || e);
      return { ok: false, error, output: error };
    }
  }
  const { stdout } = await shEngvpnd("warp", command || "status");
  return { ok: true, output: stdout.trim() };
}

/* ─── StealthSurf public API (user API key) ─── */

export function readAccountFile() {
  if (!existsSync(ACCOUNT_PATH)) {
    return { apiKey: "", subscriptionUrl: "", email: "", balance: null, subscriptionKey: "", lastSync: 0, active: false };
  }
  try {
    return { apiKey: "", subscriptionUrl: "", email: "", balance: null, subscriptionKey: "", lastSync: 0, active: false, ...JSON.parse(readFileSync(ACCOUNT_PATH, "utf8")) };
  } catch {
    return { apiKey: "", subscriptionUrl: "", email: "", balance: null, subscriptionKey: "", lastSync: 0, active: false };
  }
}

export function writeAccountFile( partial ) {
  mkdirSync(DATA, { recursive: true });
  const next = { ...readAccountFile(), ...partial };
  writeFileSync(ACCOUNT_PATH, `${JSON.stringify(next, null, 2)}\n`, { mode: 0o600 });
  return next;
}

function maskKey(key) {
  const k = String(key || "");
  if (k.length < 16) return k ? "••••" : "";
  return `${k.slice(0, 10)}…${k.slice(-4)}`;
}

async function ssFetch(path, apiKey) {
  const res = await fetch(`${SS_API}${path}`, {
    headers: {
      Authorization: `Bearer ${apiKey}`,
      Accept: "application/json",
      "User-Agent": "EngVPN/0.5",
    },
    signal: AbortSignal.timeout(30000),
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok || data.status === false) {
    const msg = data.message || data.error || `HTTP ${res.status}`;
    const err = new Error(msg);
    err.status = res.status;
    throw err;
  }
  return data.data;
}

/** Page through GET /configs until empty (docs: limit 1–1000, default 100). */
async function ssFetchAllConfigs(apiKey) {
  const page = 200;
  const all = [];
  for (let offset = 0; offset < 5000; offset += page) {
    const chunk = await ssFetch(`/configs?limit=${page}&offset=${offset}`, apiKey);
    const rows = Array.isArray(chunk) ? chunk.filter(Boolean) : [];
    all.push(...rows);
    if (rows.length < page) break;
  }
  return all;
}

async function ssFetchLocationsMap(apiKey) {
  try {
    const list = await ssFetch("/locations", apiKey);
    const map = new Map();
    for (const loc of Array.isArray(list) ? list : []) {
      if (!loc || loc.id == null) continue;
      map.set(Number(loc.id), loc);
    }
    return map;
  } catch {
    return new Map();
  }
}

/** Soft: cloud-server VPN configs (failures ignored — not every account has them). */
async function ssFetchCloudConfigs(apiKey) {
  const out = [];
  try {
    const servers = await ssFetch("/cloud-servers?limit=100&offset=0", apiKey);
    const list = Array.isArray(servers) ? servers.filter(Boolean) : [];
    for (const srv of list.slice(0, 50)) {
      const sid = srv.id ?? srv.server_id;
      if (sid == null) continue;
      try {
        const cfgs = await ssFetch(`/cloud-servers/${sid}/configs`, apiKey);
        for (const cfg of Array.isArray(cfgs) ? cfgs.filter(Boolean) : []) {
          out.push({
            ...cfg,
            title: cfg.title || srv.title || `Cloud #${sid}`,
            _cloudServerId: sid,
            _sourceKind: "cloud",
          });
        }
      } catch {
        /* skip one server */
      }
    }
  } catch {
    /* no cloud servers */
  }
  return out;
}

function flagFromLocation(loc, cfg = {}) {
  const code = String(loc?.code || cfg.country || cfg.flag || "").toLowerCase();
  if (code.length === 2) return code;
  if (cfg.flag && String(cfg.flag).length <= 4) return String(cfg.flag).toLowerCase();
  return "auto";
}

function cfgToNode(cfg, { parseShareLink, locations } = {}) {
  const url = cfg.connection_url || cfg.uri || "";
  if (!url) return null;
  const loc = locations?.get?.(Number(cfg.location_id));
  const baseName = cfg.title || loc?.title || loc?.caption || `SS #${cfg.id}`;
  const flag = flagFromLocation(loc, cfg);
  const until = untilFromTs(cfg.expires_at) || cfg.until || "";
  const online = cfg.is_online !== false;
  const idPrefix = cfg._sourceKind === "cloud" ? `ss-cloud-${cfg._cloudServerId}-` : "ss-";
  const id = `${idPrefix}${cfg.id}`;
  if (parseShareLink && !String(url).startsWith("[")) {
    try {
      const parsed = parseShareLink(url);
      if (parsed) {
        return {
          ...parsed,
          id,
          name: baseName || parsed.name,
          until: until || parsed.until || "",
          online,
          flag: flag !== "auto" ? flag : parsed.flag || "auto",
          country: loc?.code || parsed.country || "auto",
          source: cfg._sourceKind === "cloud" ? "stealthsurf-cloud" : "stealthsurf-api",
          ssConfigId: cfg.id,
          locationId: cfg.location_id ?? null,
          protocol: cfg.protocol || parsed.protocol,
        };
      }
    } catch {
      /* fallthrough */
    }
  }
  const n = nodeFromConnectionUrl(url, { ...cfg, title: baseName, flag, until, is_online: online });
  if (!n) return null;
  n.id = id;
  n.flag = flag;
  n.country = loc?.code || n.country || "auto";
  n.locationId = cfg.location_id ?? null;
  if (cfg._sourceKind === "cloud") n.source = "stealthsurf-cloud";
  if (cfg.protocol) n.protocol = String(cfg.protocol).replace(/-2410$/, "").replace(/^amnezia-wg.*/, "amneziawg") || n.protocol;
  return n;
}

function untilFromTs(ts) {
  if (!ts) return "";
  try {
    return new Date(Number(ts) * 1000).toISOString().slice(0, 10);
  } catch {
    return "";
  }
}

function nodeFromConnectionUrl(url, meta = {}) {
  const raw = String(url || "").trim();
  if (!raw) return null;
  // Share-link parsers live in subscription.mjs — we store raw + best-effort fields.
  let protocol = "vless";
  if (/^trojan:\/\//i.test(raw)) protocol = "trojan";
  else if (/^ss:\/\//i.test(raw)) protocol = "shadowsocks";
  else if (/^hysteria2:\/\//i.test(raw) || /^hy2:\/\//i.test(raw)) protocol = "hysteria2";
  else if (/^\[Interface\]/i.test(raw) || /PrivateKey\s*=/.test(raw)) protocol = "wireguard";
  else if (/^vless:\/\//i.test(raw)) protocol = "vless";
  else if (/^vmess:\/\//i.test(raw)) protocol = "vmess";
  const id = `ss-${meta.id || randomUUID().slice(0, 8)}`;
  return {
    id,
    name: meta.title || meta.name || `SS #${meta.id || id}`,
    protocol,
    country: meta.country || "auto",
    flag: meta.flag || "auto",
    until: untilFromTs(meta.expires_at) || meta.until || "",
    online: meta.is_online !== false,
    shareUrl: raw.startsWith("[") ? "" : raw,
    rawConfig: raw.startsWith("[") ? raw : "",
    source: "stealthsurf-api",
    ssConfigId: meta.id,
  };
}

/**
 * Save API key and/or manual subscription URL; sync configs when key is valid.
 * Invoked from panel: saveAccount / syncAccount / clearAccount.
 */
export async function engvpnSaveAccount(body = {}, state, helpers = {}) {
  const { parseShareLink, parseSubscriptionBody, directNode, saveState, snapshot, refreshSubscription } = helpers;
  const apiKey = String(body.apiKey ?? body.api_key ?? "").trim();
  const subscriptionUrl = String(body.subscriptionUrl ?? body.subscription_url ?? "").trim();
  const clearKey = body.clearKey === true;

  if (clearKey) {
    writeAccountFile({ apiKey: "", active: false, email: "", balance: null, referralBalance: null, configsCount: 0, subscriptionKey: "", lastSync: 0 });
    if (state.account) {
      state.account.email = state.account.email || "";
      state.account.subscriptionName = "Локальные подписки";
      state.account.balance = null;
      state.account.referralBalance = null;
      state.account.configsCount = 0;
      state.account.apiKeySet = false;
      state.account.apiKeyMasked = "";
      state.account.cloud = false;
    }
    saveState?.(state);
    return snapshot?.() || { ok: true };
  }

  const acct = writeAccountFile({
    apiKey: apiKey || readAccountFile().apiKey,
    subscriptionUrl: subscriptionUrl || readAccountFile().subscriptionUrl,
  });

  // Manual subscription URL path (when key empty/inactive or explicitly provided)
  if (subscriptionUrl && (!apiKey || body.preferUrl)) {
    writeAccountFile({ subscriptionUrl, active: Boolean(acct.apiKey && acct.active) });
    if (state) {
      const name = body.name || "Подписка по URL";
      const direct = typeof directNode === "function" ? directNode() : { id: "direct", name: "Без VPN", protocol: "direct" };
      let sub = (state.subscriptions || []).find((s) => s.id === "manual-url");
      if (!sub) {
        sub = { id: "manual-url", name, url: "", nodes: [direct], builtin: false, source: "manual-url" };
        state.subscriptions = [...(state.subscriptions || []).filter((s) => s.id !== "manual-url"), sub];
      } else {
        sub.name = name;
      }
      if (/^https?:\/\//i.test(subscriptionUrl)) {
        sub.url = subscriptionUrl;
        state.activeSubscription = sub.id;
        state.account = state.account || {};
        state.account.subscriptionName = name;
        state.account.subscriptionUrl = subscriptionUrl;
        state.account.apiKeySet = !!acct.apiKey && !!acct.active;
        state.account.apiKeyMasked = maskKey(acct.apiKey);
        saveState?.(state);
        if (refreshSubscription) return refreshSubscription(sub.id);
      } else if (parseShareLink) {
        const node = parseShareLink(subscriptionUrl);
        if (!node) throw new Error("Не похоже на ссылку подписки или vless/trojan/ss");
        sub.url = "";
        sub.nodes = [node, direct];
        state.activeSubscription = sub.id;
        state.account = state.account || {};
        state.account.subscriptionName = name;
        state.account.subscriptionUrl = subscriptionUrl;
        state.account.apiKeySet = !!acct.apiKey && !!acct.active;
        state.account.apiKeyMasked = maskKey(acct.apiKey);
        saveState?.(state, true);
        return snapshot?.() || { ok: true, mode: "share-link" };
      } else {
        throw new Error("Нужна https:// ссылка или строка конфига");
      }
    }
    return { ok: true, mode: "subscription-url" };
  }

  if (!apiKey && !acct.apiKey) {
    // No key: keep URL fields available
    writeAccountFile({ active: false });
    if (state?.account) {
      state.account.apiKeySet = false;
      state.account.apiKeyMasked = "";
      saveState?.(state);
    }
    return { ok: true, mode: "empty", needKeyOrUrl: true };
  }

  const key = apiKey || acct.apiKey;
  if (!API_KEY_RE.test(key)) {
    throw new Error("Ключ должен быть вида stlth_<8 hex>_<24 hex> (см. docs.stealthsurf.net/api)");
  }

  const profile = await ssFetch("/profile", key);
  const [list, locations, cloudList] = await Promise.all([
    ssFetchAllConfigs(key),
    ssFetchLocationsMap(key),
    ssFetchCloudConfigs(key),
  ]);

  const nodes = [];
  const seen = new Set();
  for (const cfg of [...list, ...cloudList]) {
    const n = cfgToNode(cfg, { parseShareLink, locations });
    if (!n || seen.has(n.id)) continue;
    seen.add(n.id);
    nodes.push(n);
  }

  const balance = profile?.balance != null ? Number(profile.balance) : null;
  const referralBalance = profile?.referral_balance != null ? Number(profile.referral_balance) : null;

  writeAccountFile({
    apiKey: key,
    active: true,
    email: profile?.email || "",
    balance: Number.isFinite(balance) ? balance : null,
    referralBalance: Number.isFinite(referralBalance) ? referralBalance : null,
    subscriptionKey: profile?.subscription_key || "",
    lastSync: Date.now(),
    profileId: profile?.id,
    configsCount: nodes.length,
  });

  if (state) {
    state.account = state.account || {};
    state.account.email = profile?.email || state.account.email || "";
    state.account.subscriptionName = "Основная подписка (API)";
    state.account.subscriptionUrl = subscriptionUrl || readAccountFile().subscriptionUrl || state.account.subscriptionUrl || "";
    state.account.balance = Number.isFinite(balance) ? balance : null;
    state.account.referralBalance = Number.isFinite(referralBalance) ? referralBalance : null;
    state.account.apiKeySet = true;
    state.account.apiKeyMasked = maskKey(key);
    state.account.cloud = true;
    state.account.stub = "";
    state.account.configsCount = nodes.length;
    let sub = (state.subscriptions || []).find((s) => s.id === "ss-api");
    const direct = typeof directNode === "function" ? directNode() : { id: "direct", name: "Без VPN", protocol: "direct" };
    if (!sub) {
      sub = { id: "ss-api", name: "StealthSurf API", url: "", nodes: [], builtin: false, source: "stealthsurf-api" };
      state.subscriptions = [...(state.subscriptions || []), sub];
    }
    sub.name = `StealthSurf API (${nodes.length})`;
    sub.nodes = [...nodes, direct];
    sub.updatedAt = Date.now();
    state.activeSubscription = "ss-api";
    // Point selection at an API node so home «Локации» shows the synced list
    const stillValid = nodes.some((n) => n.id === state.vpn?.selectedId);
    if (!stillValid && nodes[0]) {
      state.vpn = state.vpn || {};
      state.vpn.selectedId = nodes[0].id;
      state.vpn.lastVpnId = nodes[0].id;
    } else if (stillValid && state.vpn) {
      state.vpn.lastVpnId = state.vpn.selectedId;
    }
    if (subscriptionUrl) {
      writeAccountFile({ subscriptionUrl });
    }
    saveState?.(state, true);
    return snapshot?.() || { ok: true, nodes: nodes.length, email: profile?.email, balance, referralBalance };
  }
  return { ok: true, nodes: nodes.length, email: profile?.email, balance, referralBalance };
}

export async function engvpnSyncAccount(state, helpers) {
  const acct = readAccountFile();
  if (!acct.apiKey || !acct.active) {
    if (acct.subscriptionUrl) {
      return engvpnSaveAccount({ subscriptionUrl: acct.subscriptionUrl, preferUrl: true }, state, helpers);
    }
    throw new Error("Нет активного API-ключа. Введите stlth_… или URL подписки.");
  }
  return engvpnSaveAccount({ apiKey: acct.apiKey }, state, helpers);
}

function loadAvgCpuPct() {
  try {
    const la = loadavg()[0] || 0;
    const n = Math.max(1, cpus()?.length || 1);
    return Math.min(100, Math.round((la / n) * 100));
  } catch {
    return 0;
  }
}

function readDpiStatus() {
  const path = join(DATA, "dpi.conf");
  const cur = { enabled: false };
  if (existsSync(path)) {
    for (const line of readFileSync(path, "utf8").split("\n")) {
      const m = line.match(/^([a-z_]+)=(.*)$/);
      if (m) cur[m[1]] = m[2];
    }
  }
  return {
    enabled: cur.enabled === "1",
    youtube: cur.youtube !== "0",
    discord: cur.discord !== "0",
    queue: Number(cur.queue || 390),
    engine: "nfqws",
    open: true,
  };
}

/* ─── LAN discovery (ARP / neigh / dnsmasq) ─── */

function normalizeMac(mac) {
  return String(mac || "")
    .trim()
    .toLowerCase()
    .replace(/-/g, ":");
}

function deviceIdFromMac(mac) {
  const clean = normalizeMac(mac).replace(/:/g, "");
  return clean ? `lan-${clean.slice(-8)}` : `lan-${randomUUID().slice(0, 8)}`;
}

function parseProcArp() {
  const path = "/proc/net/arp";
  if (!existsSync(path)) return [];
  const out = [];
  for (const line of readFileSync(path, "utf8").split("\n").slice(1)) {
    const parts = line.trim().split(/\s+/);
    if (parts.length < 4) continue;
    const [ip, , , mac] = parts;
    if (!mac || mac === "00:00:00:00:00:00") continue;
    if (!/^\d+\.\d+\.\d+\.\d+$/.test(ip)) continue;
    out.push({ ip, mac: normalizeMac(mac), online: true, name: "" });
  }
  return out;
}

function parseDnsmasqLeases() {
  const candidates = [
    "/var/lib/misc/dnsmasq.leases",
    "/tmp/dnsmasq.leases",
    "/tmp/var/lib/misc/dnsmasq.leases",
    "/jffs/dnsmasq.leases",
    join(DATA, "dnsmasq.leases"),
  ];
  const out = [];
  for (const path of candidates) {
    if (!existsSync(path)) continue;
    for (const line of readFileSync(path, "utf8").split("\n")) {
      const parts = line.trim().split(/\s+/);
      if (parts.length < 4) continue;
      const [, mac, ip, host] = parts;
      if (!mac || !ip) continue;
      out.push({
        ip,
        mac: normalizeMac(mac),
        online: true,
        name: host && host !== "*" ? host : "",
      });
    }
  }
  return out;
}

function parseNvramNames() {
  const map = new Map();
  try {
    // Best-effort: custom_clientlist from a cached file written by discover script
    const cache = join(DATA, "client-names.tsv");
    if (existsSync(cache)) {
      for (const line of readFileSync(cache, "utf8").split("\n")) {
        const [mac, name] = line.split("\t");
        if (mac && name) map.set(normalizeMac(mac), name);
      }
    }
  } catch {
    /* ignore */
  }
  return map;
}

/** Merge shell discover JSONL + local ARP/leases; preserve panel exclusions/names. */
export function discoverLanDevices(state) {
  const byIp = new Map();
  const absorb = (row) => {
    if (!row?.ip || !row?.mac) return;
    if (row.ip.startsWith("127.") || row.ip === "0.0.0.0") return;
    const prev = byIp.get(row.ip) || {};
    byIp.set(row.ip, {
      ip: row.ip,
      mac: normalizeMac(row.mac || prev.mac),
      name: row.name || prev.name || "",
      online: row.online !== false,
    });
  };
  for (const row of parseDnsmasqLeases()) absorb(row);
  for (const row of parseProcArp()) absorb(row);

  // Shell helper (ip neigh + nvram names) when available
  try {
    const script = join(SHARE, "discover-devices.sh");
    if (existsSync(script)) {
      const cached = join(DATA, "discover.cache.jsonl");
      if (existsSync(cached)) {
        for (const line of readFileSync(cached, "utf8").split("\n")) {
          if (!line.trim()) continue;
          try {
            absorb(JSON.parse(line));
          } catch {
            /* ignore */
          }
        }
      }
      let dir = "";
      try {
        dir = mkdtempSync(join(tmpdir(), "engvpn-disc-"));
        const outFile = join(dir, "out.jsonl");
        execFileSync("sh", [script, outFile], {
          env: { ...process.env, ENGVPN_DATA_DIR: DATA },
          timeout: 4000,
        });
        if (existsSync(outFile)) {
          const body = readFileSync(outFile, "utf8");
          writeFileSync(cached, body, { mode: 0o600 });
          for (const line of body.split("\n")) {
            if (!line.trim() || line.startsWith("count=")) continue;
            try {
              absorb(JSON.parse(line));
            } catch {
              /* ignore */
            }
          }
        }
      } catch {
        /* discover optional on non-Merlin hosts */
      } finally {
        if (dir) {
          try {
            rmSync(dir, { recursive: true, force: true });
          } catch {
            /* ignore */
          }
        }
      }
    }
  } catch {
    /* ignore */
  }

  const names = parseNvramNames();
  const existing = new Map((state?.devices || []).map((d) => [d.ip, d]));
  const existingByMac = new Map((state?.devices || []).map((d) => [normalizeMac(d.mac), d]));
  const devices = [];
  for (const row of byIp.values()) {
    const prev = existing.get(row.ip) || existingByMac.get(row.mac) || {};
    const name = prev.name && !prev.demo ? prev.name : row.name || names.get(row.mac) || row.ip;
    devices.push({
      id: prev.id || deviceIdFromMac(row.mac),
      name,
      ip: row.ip,
      mac: row.mac,
      online: row.online !== false,
      isNew: prev.isNew ?? !prev.id,
      excluded: !!prev.excluded,
      route: prev.route || "default",
      configId: prev.configId || "",
      bypass: prev.bypass || [],
      traffic: prev.traffic || { session: 0, today: 0, d7: 0, d30: 0 },
      demo: false,
    });
  }
  devices.sort((a, b) => a.ip.localeCompare(b.ip, undefined, { numeric: true }));
  return devices;
}

/** Replace demo devices with live LAN list when discovery finds anything. */
export function mergeDiscoveredDevices(state) {
  if (!state) return [];
  const found = discoverLanDevices(state);
  if (!found.length) {
    // Keep non-demo user-added devices; drop demo placeholders when on Merlin-ish host
    const real = (state.devices || []).filter((d) => !d.demo);
    if (real.length) {
      state.devices = real;
      return real;
    }
    return state.devices || [];
  }
  // Preserve manually added offline devices not seen in ARP
  const seen = new Set(found.map((d) => d.ip));
  for (const d of state.devices || []) {
    if (d.demo) continue;
    if (seen.has(d.ip)) continue;
    found.push({ ...d, online: false, demo: false });
  }
  state.devices = found;
  return found;
}

/* ─── SmartDNS bypass (local domain/IP list) ─── */

export function readSmartDns() {
  const confPath = join(DATA, "smartdns.conf");
  const listPath = join(DATA, "smartdns-bypass.txt");
  let enabled = false;
  if (existsSync(confPath)) {
    for (const line of readFileSync(confPath, "utf8").split("\n")) {
      const m = line.match(/^enabled=(.*)$/);
      if (m) enabled = m[1] === "1";
    }
  }
  const entries = [];
  if (existsSync(listPath)) {
    for (const line of readFileSync(listPath, "utf8").split("\n")) {
      const t = line.trim();
      if (!t || t.startsWith("#")) continue;
      entries.push(t);
    }
  }
  return { enabled, entries, stub: false, note: "" };
}

export function writeSmartDns({ enabled, entries } = {}) {
  mkdirSync(DATA, { recursive: true });
  const cur = readSmartDns();
  const nextEnabled = enabled != null ? !!enabled : cur.enabled;
  const nextEntries = Array.isArray(entries) ? entries.map((e) => String(e).trim()).filter(Boolean) : cur.entries;
  writeFileSync(join(DATA, "smartdns.conf"), `enabled=${nextEnabled ? "1" : "0"}\n`, { mode: 0o600 });
  writeFileSync(
    join(DATA, "smartdns-bypass.txt"),
    `# EngVPN SmartDNS bypass — domain, IP or CIDR per line\n${nextEntries.join("\n")}${nextEntries.length ? "\n" : ""}`,
    { mode: 0o600 },
  );
  return { enabled: nextEnabled, entries: nextEntries, stub: false };
}

export async function engvpnSmartDns(command = "status", body = {}) {
  if (body && typeof body === "object") {
    if (body.enabled != null || Array.isArray(body.entries) || Array.isArray(body.domains)) {
      const entries = body.entries || body.domains;
      writeSmartDns({ enabled: body.enabled, entries });
    }
    if (typeof body.text === "string") {
      const entries = body.text
        .split(/\r?\n/)
        .map((l) => l.trim())
        .filter((l) => l && !l.startsWith("#"));
      writeSmartDns({ enabled: body.enabled, entries });
    }
  }
  const action = command === "save" ? "apply" : command || "status";
  try {
    const { stdout } = await shEngvpnd("smartdns", action === "get" ? "status" : action);
    return { ok: true, ...readSmartDns(), output: stdout.trim() };
  } catch (e) {
    const error = String(e.message || e);
    // Never fake success — UI must surface apply/status failures.
    return { ok: false, error, ...readSmartDns(), output: error };
  }
}

export async function engvpnBackup(command = "latest", prefix) {
  const args = [command || "latest"];
  if (prefix) args.push(prefix);
  const { stdout } = await shEngvpnd("backup", ...args);
  return { ok: true, output: stdout.trim() };
}

/**
 * Remove alfa placeholder locations (alpha:true VPN rows). They look “live”
 * (NL Trojan / сервер онлайн) but never connect — confuse users with no API key.
 * Keep real synced/local nodes and the direct profile.
 */
export function scrubAlphaDemoNodes(target) {
  if (!target?.subscriptions || !Array.isArray(target.subscriptions)) return false;
  let changed = false;
  const direct = {
    id: "direct",
    name: "Без VPN",
    protocol: "direct",
    country: "",
    flag: "direct",
    until: "",
    online: true,
  };
  for (const sub of target.subscriptions) {
    const prev = sub.nodes || [];
    const next = prev.filter((n) => n && (n.protocol === "direct" || !n.alpha));
    if (next.length !== prev.length) {
      sub.nodes = next;
      changed = true;
    }
    if (!(sub.nodes || []).some((n) => n.protocol === "direct")) {
      sub.nodes = [...(sub.nodes || []), { ...direct }];
      changed = true;
    }
  }
  const ids = new Set();
  let hasReal = false;
  for (const sub of target.subscriptions) {
    for (const n of sub.nodes || []) {
      ids.add(n.id);
      if (n.protocol !== "direct") hasReal = true;
    }
  }
  if (target.vpn && !ids.has(target.vpn.selectedId)) {
    target.vpn.selectedId = hasReal
      ? [...ids].find((id) => id !== "direct") || "direct"
      : "direct";
    if (!hasReal) target.vpn.lastVpnId = "";
    changed = true;
  }
  return changed;
}

/**
 * Keep panel snapshot in sync with on-disk EngVPN files (account.json, transparent.conf).
 * Mutates state.account / state.router when provided so subsequent patches stay consistent.
 */
export function hydratePanelSnapshot(snap, state) {
  if (!snap || typeof snap !== "object") return snap;
  try {
    const acct = readAccountFile();
    const account = { ...(snap.account || {}) };
    account.apiKeySet = !!(acct.apiKey && acct.active);
    account.apiKeyMasked = maskKey(acct.apiKey);
    account.subscriptionUrl = acct.subscriptionUrl || account.subscriptionUrl || "";
    if (acct.email) account.email = acct.email;
    if (acct.balance != null) account.balance = acct.balance;
    if (acct.referralBalance != null) account.referralBalance = acct.referralBalance;
    if (acct.configsCount != null) account.configsCount = acct.configsCount;
    if (account.apiKeySet && !account.subscriptionName) account.subscriptionName = "Основная подписка (API)";
    if (!account.apiKeySet && (!account.subscriptionName || account.subscriptionName === "Основная подписка")) {
      account.subscriptionName = account.subscriptionUrl ? "Подписка по URL" : "Локальные подписки";
    }
    account.cloud = !!account.apiKeySet;
    account.hasCredentials = !!(account.apiKeySet || (account.subscriptionUrl && String(account.subscriptionUrl).trim()));
    snap.account = account;
    if (state) {
      state.account = { ...(state.account || {}), ...account };
    }
  } catch {
    /* ignore */
  }
  try {
    scrubAlphaDemoNodes(snap);
    if (state) scrubAlphaDemoNodes(state);
  } catch {
    /* ignore */
  }
  try {
    const conf = readTransparentConf();
    if (snap.router) {
      snap.router.transparentMethod = conf.method || snap.router.transparentMethod || "auto";
      if (state?.router) state.router.transparentMethod = snap.router.transparentMethod;
    }
  } catch {
    /* ignore */
  }
  try {
    if (!snap.smartdns) snap.smartdns = readSmartDns();
  } catch {
    snap.smartdns = { enabled: false, entries: [] };
  }
  try {
    const uc = readUpdatesConf();
    if (!snap.updates) snap.updates = {};
    const mem = state?.updates && typeof state.updates === "object" ? state.updates : null;
    const confExists = existsSync(join(DATA, "updates.conf"));
    // In-memory wins during patch-in-flight (conf is written by syncUpdatesSchedule after).
    // Conf fills gaps / cold hydrate. Never clobber a just-patched auto/interval back to stale conf.
    if (typeof mem?.auto === "boolean") snap.updates.auto = !!mem.auto;
    else if (confExists) snap.updates.auto = !!uc.auto;
    else if (typeof snap.updates.auto !== "boolean") snap.updates.auto = !!uc.auto;

    snap.updates.interval = mem?.interval || (confExists ? uc.interval : null) || snap.updates.interval || "1d";
    snap.updates.windowStart = mem?.windowStart ?? (confExists ? uc.windowStart : snap.updates.windowStart) ?? 2;
    snap.updates.windowEnd = mem?.windowEnd ?? (confExists ? uc.windowEnd : snap.updates.windowEnd) ?? 5;
    snap.updates.geoWeekly = typeof mem?.geoWeekly === "boolean"
      ? mem.geoWeekly
      : (confExists ? uc.geoWeekly : snap.updates.geoWeekly !== false);
    snap.updates.coresWhenMissing = typeof mem?.coresWhenMissing === "boolean"
      ? mem.coresWhenMissing
      : (confExists ? uc.coresWhenMissing : snap.updates.coresWhenMissing !== false);
    if (mem?.lastCheck != null) snap.updates.lastCheck = mem.lastCheck;
    else if (uc.lastCheck) snap.updates.lastCheck = uc.lastCheck;
    if (mem?.lastResult) snap.updates.lastResult = mem.lastResult;
    else if (uc.lastResult) snap.updates.lastResult = uc.lastResult;
    if (typeof mem?.available === "boolean") snap.updates.available = mem.available;
    else if (typeof snap.updates.lastResult === "string") {
      snap.updates.available = /^(available|available-wait-window):/.test(snap.updates.lastResult);
    }
    if (mem?.latest) snap.updates.latest = mem.latest;
    else if (typeof snap.updates.lastResult === "string") {
      const m = snap.updates.lastResult.match(/^(?:available|available-wait-window|up-to-date|applied):(.+)$/);
      if (m?.[1]) snap.updates.latest = m[1];
    }
    if (state) {
      // Merge into state without letting stale conf wipe in-memory schedule toggles
      state.updates = { ...(uc && confExists ? {
        interval: uc.interval,
        auto: !!uc.auto,
        windowStart: uc.windowStart,
        windowEnd: uc.windowEnd,
        geoWeekly: uc.geoWeekly,
        coresWhenMissing: uc.coresWhenMissing,
        lastCheck: uc.lastCheck,
        lastResult: uc.lastResult,
      } : {}), ...(state.updates || {}), ...{
        auto: snap.updates.auto,
        interval: snap.updates.interval,
        windowStart: snap.updates.windowStart,
        windowEnd: snap.updates.windowEnd,
        geoWeekly: snap.updates.geoWeekly,
        coresWhenMissing: snap.updates.coresWhenMissing,
        lastCheck: snap.updates.lastCheck,
        lastResult: snap.updates.lastResult,
        available: snap.updates.available,
        latest: snap.updates.latest,
      } };
    }
  } catch {
    /* ignore */
  }
  return snap;
}

/** StealthSurf-shaped get_* helpers backed by EngVPN panel state + daemon. */
export function engvpnParityInvoke(command, body, state, snapshotFn) {
  const snap = typeof snapshotFn === "function" ? snapshotFn() : state;
  const acct = readAccountFile();
  switch (command) {
    case "get_bootstrap":
    case "get_bootstrap_capabilities":
      return {
        brand: "EngVPN",
        version: state.version,
        platform: "linux",
        router: true,
        routerPlatform: "merlin",
        capabilities: {
          router: true,
          routerTransparent: true,
          routerUpdates: true,
          // Adblock/DNS lock REAL when transparent DNS :53 → EngVPN :5353 hijack is on
          routerAdBlock: true,
          routerDnsHijack: true,
          routerCaptivePortal: true,
          routerNewDevices: true,
          trafficGraph: true,
          // Zapret UI drives open dpi.sh/nfqws (needs NFQUEUE); path-probe alone is not success
          zapret: true,
          dpi: true,
          privacyChecks: true,
          leakTest: true,
          telegramDirect: true,
          smartDns: true,
          lanProxyServer: true,
          lanDiscover: true,
          backup: true,
          warp: true,
          gre: true,
          // Proprietary StealthSurf desktop / Stream Deck — not on open stack
          gaming: false,
          tray: false,
          streamDeck: false,
          cloudAccount: true,
          apiKeys: true,
          // Support = docs/GitHub link from panel (not SS live chat)
          supportLink: true,
          // Ferrum closed binary MISSING — open Xray Reality slot only
          ferrumProprietary: false,
          ferrumOpenXray: true,
        },
        engines: ["auto", "xray", "ferrum", "sing-box", "mihomo"],
        note: "Ferrum = открытый Xray Reality (не проприетарный Ferrum SS). DPI = zapret/nfqws. WARP = Cloudflare API (не MASQUE). Gaming/Stream Deck — нет.",
      };
    case "get_settings":
      return snap;
    case "get_router_settings": {
      const r = state.router || {};
      const conf = readTransparentConf();
      return {
        transparentMode: conf.mode === "selected" ? "include" : conf.mode === "exclude" ? "exclude" : conf.mode === "all" ? "all" : modeFromRouter(r.mode) === "selected" ? "include" : modeFromRouter(r.mode) === "exclude" ? "exclude" : modeFromRouter(r.mode),
        transparentDevices: (state.devices || []).filter((d) => d.excluded).map((d) => d.mac),
        dnsHijack: !!r.dnsViaVpn,
        blockQuic: !!r.blockQuic,
        blockEncryptedDns: !!r.dnsLock,
        killSwitch: !!r.blockWithoutVpn || conf.killswitch === "1",
        blockIpv6: r.ipv6 === "block",
        carryIpv6: r.ipv6 === "vpn",
        adBlock: !!r.adblock,
        captivePortal: !!r.trips,
        vpnSchedule: !!r.scheduleEnabled,
        failoverConfigs: r.reserveId ? [r.reserveId] : [],
        pcGamesDirect: !!r.gamesDirect,
        loadMonitor: !!(state.diagnostics && state.diagnostics.showLoad),
        transparentMethod: conf.method || "redirect",
      };
    }
    case "get_router_info":
    case "get_platform":
      return {
        model: state.about?.model || hostname(),
        firmware: state.about?.firmware || platform(),
        memory: state.about?.memory || `${Math.round(totalmem() / 1024 / 1024 / 1024)} ГБ`,
        arch: state.about?.arch || arch(),
        version: state.version,
        panelUrl: `http://0.0.0.0:${process.env.ENGVPN_PORT || 8790}`,
        brand: "EngVPN",
      };
    case "get_router_devices":
    case "get_router_new_devices":
    case "scan_devices": {
      const list = mergeDiscoveredDevices(state);
      return list.map((d) => ({
        ip: d.ip,
        mac: d.mac,
        name: d.name,
        routerName: d.name,
        online: !!d.online,
        new: !!d.isNew,
        excluded: !!d.excluded,
        sentBytes: d.traffic?.session || 0,
        receivedBytes: 0,
        demo: !!d.demo,
      }));
    }
    case "get_router_load":
    case "get_load_monitor":
      return {
        cpu: state.runtime?.load?.cpu ?? loadAvgCpuPct(),
        ramUsed: state.runtime?.load?.ramUsed ?? totalmem() - freemem(),
        ramTotal: state.runtime?.load?.ramTotal ?? totalmem(),
        proc: state.runtime?.load?.proc ?? 0,
      };
    case "get_router_traffic_history":
    case "get_traffic_graph":
      return { history: state.runtime?.history || [], rates: state.runtime?.rates || {} };
    case "get_router_ad_block":
      return state.router?.adStats || { today: 0, week: 0, recent: [], top: {} };
    case "external_ip":
    case "get_public_ip":
      return {
        ip: state.runtime?.exitIp || state.runtime?.publicIp || "",
        connected: !!state.vpn?.connected,
      };
    case "get_transparent_mode":
    case "get_transparent_status": {
      const conf = readTransparentConf();
      return { mode: conf.mode || "off", method: conf.method || "redirect", killswitch: conf.killswitch === "1", ...conf };
    }
    case "get_vpn_status":
      return {
        connected: !!state.vpn?.connected,
        directMode: !!state.vpn?.directMode,
        selectedId: state.vpn?.selectedId,
        exitIp: state.runtime?.exitIp || "",
      };
    case "get_selected_config": {
      for (const sub of state.subscriptions || []) {
        const node = (sub.nodes || []).find((n) => n.id === state.vpn?.selectedId);
        if (node) return node;
      }
      return null;
    }
    case "get_subscription_info":
    case "get_user":
      return {
        email: state.account?.email || acct.email || "",
        subscriptionName: state.account?.subscriptionName || (acct.active ? "Основная подписка (API)" : "Локальные подписки"),
        cloud: !!acct.active,
        balance: acct.balance ?? state.account?.balance ?? null,
        referralBalance: acct.referralBalance ?? state.account?.referralBalance ?? null,
        configsCount: acct.configsCount ?? state.account?.configsCount ?? null,
        apiKeySet: !!(acct.apiKey && acct.active),
        apiKeyMasked: maskKey(acct.apiKey),
        subscriptionUrl: acct.subscriptionUrl || "",
        stub: "",
      };
    case "get_account":
      return {
        email: acct.email || state.account?.email || "",
        balance: acct.balance,
        referralBalance: acct.referralBalance ?? null,
        configsCount: acct.configsCount ?? null,
        apiKeySet: !!(acct.apiKey && acct.active),
        apiKeyMasked: maskKey(acct.apiKey),
        subscriptionUrl: acct.subscriptionUrl || "",
        subscriptionKey: acct.subscriptionKey || "",
        lastSync: acct.lastSync || 0,
        active: !!acct.active,
      };
    case "get_ui_preferences":
      return state.appearance || {};
    case "get_connection_profiles":
      return state.profiles || [];
    case "get_logs":
    case "get_connection_log":
      return state.logs || [];
    case "get_zapret_status":
    case "get_zapret_details":
      return { ...(state.network?.zapret || {}), dpi: readDpiStatus() };
    case "get_dpi_status":
      return readDpiStatus();
    case "get_privacy_status":
    case "get_stealth_status":
      return {
        alias: "privacyCheck",
        note: "Запустите privacyCheck / leakTest для живых проб",
        transparent: readTransparentConf(),
        dpi: readDpiStatus(),
        ipv6: state.router?.ipv6 || "block",
        dnsViaVpn: !!state.router?.dnsViaVpn,
        killSwitch: !!state.router?.blockWithoutVpn,
        webrtc_hint: "https://browserleaks.com/webrtc",
      };
    case "get_telegram_direct_status":
      return { enabled: !!state.network?.telegramDirect, ready: !!state.network?.telegramDirect };
    case "get_smart_dns_bypass":
    case "get_smartdns":
      return { ...readSmartDns(), path: join(DATA, "smartdns-bypass.txt") };
    case "set_smart_dns_bypass":
    case "set_smartdns":
    case "save_smartdns":
      return { alias: "engvpnSmartDns", action: "apply", ...body };
    case "engvpn_backup":
    case "backup_create":
      return { alias: "engvpnBackup", action: body?.action || "create" };
    case "get_stored_cores":
      return state.runtime?.cores || state.engine?.cores || {};
    case "get_warp_status":
    case "check_warp_route":
      return {
        mode: state.connection?.warpMode || "off",
        method: state.connection?.warpMethod || "wireguard",
        profile: state.connection?.warpProfile || null,
        open: true,
      };
    case "get_router_update":
    case "check_router_update":
      return engvpnUpdateCheck(state);
    case "apply_router_update":
    case "install_router_update":
      return { alias: "engvpnUpdateApply", ...body };
    case "update_router_settings": {
      const patch = body?.patch || body || {};
      if (!state.router) state.router = {};
      if (patch.transparentMode != null) {
        state.router.mode = routerModeFromTransparent(patch.transparentMode);
        writeTransparentConf({
          mode: modeFromRouter(state.router.mode),
          killswitch: patch.killSwitch ? "1" : undefined,
          method: patch.transparentMethod || undefined,
        });
      }
      if (patch.transparentMethod != null) writeTransparentConf({ method: patch.transparentMethod });
      if (patch.dnsHijack != null) state.router.dnsViaVpn = !!patch.dnsHijack;
      if (patch.blockQuic != null) state.router.blockQuic = !!patch.blockQuic;
      if (patch.blockEncryptedDns != null) state.router.dnsLock = !!patch.blockEncryptedDns;
      if (patch.killSwitch != null) {
        state.router.blockWithoutVpn = !!patch.killSwitch;
        writeTransparentConf({ killswitch: patch.killSwitch ? "1" : "0" });
      }
      if (patch.blockIpv6 != null) state.router.ipv6 = patch.blockIpv6 ? "block" : state.router.ipv6;
      if (patch.carryIpv6) state.router.ipv6 = "vpn";
      if (patch.adBlock != null) state.router.adblock = !!patch.adBlock;
      if (patch.captivePortal != null) state.router.trips = !!patch.captivePortal;
      if (patch.pcGamesDirect != null) state.router.gamesDirect = !!patch.pcGamesDirect;
      if (patch.vpnSchedule != null) state.router.scheduleEnabled = !!patch.vpnSchedule;
      return { ok: true, router: state.router };
    }
    case "select_config":
      return { alias: "selectNode", id: body?.id || body?.configId };
    case "set_router_panel_password":
      return { alias: "setPassword", ...body };
    case "save_account":
    case "saveAccount":
      return { alias: "engvpnSaveAccount", ...body };
    case "sync_account":
    case "syncAccount":
      return { alias: "engvpnSyncAccount" };
    case "clear_account":
    case "clearAccount":
      return { alias: "engvpnSaveAccount", clearKey: true };
    default:
      return undefined;
  }
}

/* ─── Live speed: WAN + ENGVPN iptables counters (transparent path bypasses Node proxy hooks) ─── */

function readProcNetDev() {
  try {
    const text = readFileSync("/proc/net/dev", "utf8");
    const rows = {};
    for (const line of text.split("\n")) {
      const m = line.match(/^\s*([a-zA-Z0-9._-]+):\s*(\d+)\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+(\d+)/);
      if (!m) continue;
      rows[m[1]] = { rx: Number(m[2]) || 0, tx: Number(m[3]) || 0 };
    }
    return rows;
  } catch {
    return {};
  }
}

function pickWanIfaces(rows) {
  const skip = /^(lo|br\d*|docker|veth|virbr|tun|tap|wg|engvpn|ipsec|ppp)/i;
  const preferred = Object.keys(rows).filter((n) => /^(eth|en|wan|vlan)/i.test(n) && !skip.test(n));
  const rest = Object.keys(rows).filter((n) => !skip.test(n) && !preferred.includes(n));
  const names = preferred.length ? preferred : rest;
  return names.length ? names : Object.keys(rows).filter((n) => n !== "lo");
}

function sumIptablesChainBytes(table, chain) {
  try {
    const stdout = execFileSync("iptables", ["-t", table, "-L", chain, "-nvx"], {
      encoding: "utf8",
      timeout: 1500,
      maxBuffer: 2 * 1024 * 1024,
    });
    let total = 0;
    for (const line of String(stdout || "").split("\n")) {
      if (!/TPROXY|REDIRECT|DNAT|MARK/.test(line)) continue;
      const parts = line.trim().split(/\s+/);
      // pkts bytes target ...
      if (parts.length >= 3 && /^\d+$/.test(parts[0]) && /^\d+$/.test(parts[1])) {
        total += Number(parts[1]) || 0;
      }
    }
    return total;
  } catch {
    return 0;
  }
}

/** Bytes/sec estimates for VPN vs direct — used when proxy hooks see no LAN transparent traffic. */
export function sampleRouterTraffic(live) {
  const now = Date.now();
  const ifaces = readProcNetDev();
  const wanNames = pickWanIfaces(ifaces);
  let wanRx = 0;
  let wanTx = 0;
  for (const n of wanNames) {
    wanRx += ifaces[n]?.rx || 0;
    wanTx += ifaces[n]?.tx || 0;
  }
  const vpnBytes =
    sumIptablesChainBytes("mangle", "ENGVPN") +
    sumIptablesChainBytes("nat", "ENGVPN") +
    sumIptablesChainBytes("mangle", "ENGVPN_SEL") +
    sumIptablesChainBytes("nat", "ENGVPN_SEL");

  if (!live.engvpnTraffic) live.engvpnTraffic = { last: null, lastAt: 0 };
  const cur = { wanRx, wanTx, vpnBytes };
  const prev = live.engvpnTraffic.last;
  const prevAt = live.engvpnTraffic.lastAt;
  live.engvpnTraffic.last = cur;
  live.engvpnTraffic.lastAt = now;
  if (!prev || !prevAt) {
    return { vpnDown: 0, vpnUp: 0, directDown: 0, directUp: 0 };
  }
  const dt = Math.max(0.25, (now - prevAt) / 1000);
  const wanDown = Math.max(0, (cur.wanRx - prev.wanRx) / dt);
  const wanUp = Math.max(0, (cur.wanTx - prev.wanTx) / dt);
  const vpnDelta = Math.max(0, (cur.vpnBytes - prev.vpnBytes) / dt);
  // ENGVPN counters are mostly LAN→tunnel (upload); split WAN with vpn share.
  const vpnShare = wanDown + wanUp > 0 ? Math.min(1, vpnDelta / Math.max(wanDown + wanUp, 1)) : (vpnDelta > 0 ? 0.7 : 0);
  const vpnDown = wanDown * vpnShare;
  const vpnUp = Math.max(vpnDelta * 0.5, wanUp * vpnShare);
  return {
    vpnDown,
    vpnUp,
    directDown: Math.max(0, wanDown - vpnDown),
    directUp: Math.max(0, wanUp - vpnUp),
  };
}

/** Mark cores that cannot run on this firmware (e.g. sing-box missing libresolv.so.2). */
export async function probeCoresHealth(state) {
  const { corePath } = await import("./engines.mjs").catch(() => ({}));
  const ids = ["xray", "ferrum", "sing-box", "mihomo"];
  state.engine = state.engine || {};
  state.engine.cores = state.engine.cores || {};
  for (const id of ids) {
    let bin = null;
    try {
      bin = typeof corePath === "function" ? corePath(id) : join(DATA, "cores", id === "sing-box" ? "sing-box" : id === "mihomo" ? "mihomo" : id === "ferrum" ? "ferrum" : "xray");
    } catch {
      bin = join(DATA, "cores", id === "sing-box" ? "sing-box" : id);
    }
    if (!bin || !existsSync(bin)) {
      state.engine.cores[id] = { ...(state.engine.cores[id] || {}), broken: false, softHidden: false };
      continue;
    }
    try {
      const args = id === "mihomo" ? ["-v"] : ["version"];
      const { stdout, stderr } = await exec(bin, args, { timeout: 4000 }).catch((e) => ({
        stdout: "",
        stderr: String(e?.stderr || e?.message || e),
      }));
      const out = `${stdout || ""}\n${stderr || ""}`;
      const broken = /libresolv\.so|not found|cannot open shared object|No such file|Exec format error/i.test(out)
        || (/error while loading/i.test(out) && !/Xray|sing-box|Mihomo|mihomo/i.test(out));
      // empty version + non-zero often means loader failure
      const softHidden = broken || /libresolv\.so/i.test(out);
      state.engine.cores[id] = {
        ...(state.engine.cores[id] || {}),
        broken: softHidden,
        softHidden,
        brokenReason: softHidden ? (out.match(/libresolv\.so[^\s]*/)?.[0] || "не запускается на этой прошивке") : "",
      };
    } catch (e) {
      const msg = String(e?.message || e);
      const softHidden = /libresolv|ENOENT|spawn|shared object/i.test(msg);
      state.engine.cores[id] = {
        ...(state.engine.cores[id] || {}),
        broken: softHidden,
        softHidden,
        brokenReason: softHidden ? msg.slice(0, 120) : "",
      };
    }
  }
  try {
    const { saveState } = await import("./state.mjs");
    saveState(state);
  } catch {
    /* best-effort */
  }
  return state.engine.cores;
}

export { unlinkSync, ACCOUNT_PATH, SS_API, API_KEY_RE, maskKey };
