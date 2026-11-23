/**
 * EngVPN panel extensions mixed into the vendored alfa runtime at build time.
 * Open components only — shells out to engvpnd / transparent / dpi / warp / update.
 * StealthSurf HTTP API (user-provided API keys) + local subscription URLs.
 */
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { existsSync, readFileSync, writeFileSync, mkdirSync, unlinkSync } from "node:fs";
import { join, dirname } from "node:path";
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

export async function engvpnTransparent(command, body = {}) {
  if (body && typeof body === "object") {
    const patch = {};
    if (body.mode) patch.mode = body.mode;
    if (body.method) patch.method = body.method;
    if (body.port) patch.port = String(body.port);
    if (body.killswitch != null) patch.killswitch = body.killswitch ? "1" : "0";
    if (body.routerMode) patch.mode = modeFromRouter(body.routerMode);
    if (body.transparentMode) patch.mode = modeFromRouter(body.transparentMode);
    if (Object.keys(patch).length) writeTransparentConf(patch);
    if (Array.isArray(body.devices)) {
      mkdirSync(DATA, { recursive: true });
      writeFileSync(join(DATA, "devices.select"), `${body.devices.join("\n")}\n`, { mode: 0o600 });
    }
  }
  const { stdout } = await shEngvpnd("transparent", command || "status");
  return { ok: true, output: stdout.trim() };
}

export async function engvpnUpdateCheck() {
  const { stdout } = await shEngvpnd("update-check");
  const out = {};
  for (const line of stdout.split("\n")) {
    const i = line.indexOf("=");
    if (i > 0) out[line.slice(0, i)] = line.slice(i + 1);
  }
  if (!out.message) {
    const parts = [];
    if (out.current || out.version || out.installed) parts.push(`текущая ${out.current || out.version || out.installed}`);
    if (out.latest || out.feed) parts.push(`в feed ${out.latest || out.feed}`);
    if (out.update === "1" || out.available === "1" || out.update_available === "1") parts.push("доступно обновление");
    out.message = parts.length ? parts.join(" · ") : "Проверка feed EngVPN завершена";
  }
  return out;
}

export async function engvpnReconnect() {
  const { stdout } = await shEngvpnd("reconnect");
  return { ok: true, output: stdout.trim() };
}

export async function engvpnWatchdog() {
  const { stdout } = await shEngvpnd("watchdog");
  return { ok: true, output: stdout.trim() };
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
    const { stdout } = await shEngvpnd("warp", command);
    return { ok: true, output: stdout.trim() };
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
      "User-Agent": "EngVPN/0.4",
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
    writeAccountFile({ apiKey: "", active: false, email: "", balance: null, subscriptionKey: "", lastSync: 0 });
    if (state.account) {
      state.account.email = state.account.email || "";
      state.account.subscriptionName = "Локальные подписки";
      state.account.balance = null;
      state.account.apiKeySet = false;
      state.account.apiKeyMasked = "";
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
  const configs = await ssFetch("/configs?limit=100&offset=0", key);
  const list = Array.isArray(configs) ? configs.filter(Boolean) : [];

  const nodes = [];
  for (const cfg of list) {
    const url = cfg.connection_url || cfg.uri || "";
    if (!url) continue;
    if (parseShareLink && !String(url).startsWith("[")) {
      try {
        const parsed = parseShareLink(url);
        if (parsed) {
          nodes.push({
            ...parsed,
            id: `ss-${cfg.id}`,
            name: cfg.title || parsed.name || `SS #${cfg.id}`,
            until: untilFromTs(cfg.expires_at) || parsed.until || "",
            online: cfg.is_online !== false,
            source: "stealthsurf-api",
            ssConfigId: cfg.id,
          });
          continue;
        }
      } catch { /* fallthrough */ }
    }
    const n = nodeFromConnectionUrl(url, cfg);
    if (n) nodes.push(n);
  }

  writeAccountFile({
    apiKey: key,
    active: true,
    email: profile?.email || "",
    balance: profile?.balance ?? null,
    subscriptionKey: profile?.subscription_key || "",
    lastSync: Date.now(),
    profileId: profile?.id,
  });

  if (state) {
    state.account = state.account || {};
    state.account.email = profile?.email || state.account.email || "";
    state.account.subscriptionName = "Основная подписка (API)";
    state.account.balance = profile?.balance ?? null;
    state.account.apiKeySet = true;
    state.account.apiKeyMasked = maskKey(key);
    state.account.cloud = true;
    state.account.stub = "";
    let sub = (state.subscriptions || []).find((s) => s.id === "ss-api");
    const direct = typeof directNode === "function" ? directNode() : { id: "direct", name: "Без VPN", protocol: "direct" };
    if (!sub) {
      sub = { id: "ss-api", name: "StealthSurf API", url: "", nodes: [], builtin: false, source: "stealthsurf-api" };
      state.subscriptions = [...(state.subscriptions || []), sub];
    }
    sub.nodes = [...nodes, direct];
    sub.updatedAt = Date.now();
    state.activeSubscription = "ss-api";
    // Optional: if user also pasted a subscription URL, keep it as second sub
    if (subscriptionUrl) {
      writeAccountFile({ subscriptionUrl });
    }
    saveState?.(state, true);
    return snapshot?.() || { ok: true, nodes: nodes.length, email: profile?.email };
  }
  return { ok: true, nodes: nodes.length, email: profile?.email, balance: profile?.balance };
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
          routerAdBlock: true,
          routerCaptivePortal: true,
          routerNewDevices: true,
          trafficGraph: true,
          zapret: true,
          dpi: true,
          telegramDirect: true,
          smartDns: false,
          lanProxyServer: true,
          warp: true,
          gre: true,
          gaming: false,
          tray: false,
          cloudAccount: true,
          apiKeys: true,
        },
        engines: ["auto", "xray", "ferrum", "sing-box", "mihomo"],
        note: "Ferrum-слот = открытый Xray (Reality). DPI = open zapret/nfqws. WARP = Cloudflare API.",
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
    case "scan_devices":
      return (state.devices || []).map((d) => ({
        ip: d.ip,
        mac: d.mac,
        name: d.name,
        routerName: d.name,
        online: !!d.online,
        new: !!d.isNew,
        excluded: !!d.excluded,
        sentBytes: d.traffic?.session || 0,
        receivedBytes: 0,
      }));
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
        apiKeySet: !!(acct.apiKey && acct.active),
        apiKeyMasked: maskKey(acct.apiKey),
        subscriptionUrl: acct.subscriptionUrl || "",
        stub: "",
      };
    case "get_account":
      return {
        email: acct.email || state.account?.email || "",
        balance: acct.balance,
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
    case "get_telegram_direct_status":
      return { enabled: !!state.network?.telegramDirect, ready: !!state.network?.telegramDirect };
    case "get_smart_dns_bypass":
      return { enabled: false, stub: true, note: "SmartDNS / сервисы без VPN консоли StealthSurf не клонированы" };
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
      return engvpnUpdateCheck();
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

export { unlinkSync, ACCOUNT_PATH, SS_API, API_KEY_RE, maskKey };
