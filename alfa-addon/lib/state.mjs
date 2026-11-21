import { existsSync, mkdirSync, readFileSync, writeFileSync, renameSync } from "node:fs";
import { dirname, join } from "node:path";
import { randomBytes, scryptSync, timingSafeEqual, randomUUID } from "node:crypto";
import { arch, hostname, totalmem, platform } from "node:os";
import { VERSION, engineSupports } from "./catalog.mjs";

export const ROOT = join(import.meta.dirname, "..");
export const DATA = join(ROOT, "data");
export const STATE_PATH = join(DATA, "state.json");

function hoursOn() {
  return Array.from({ length: 24 }, () => true);
}

export function hashPassword(password, salt = randomBytes(16).toString("hex")) {
  const hash = scryptSync(String(password), salt, 32).toString("hex");
  return { salt, hash };
}

export function checkPassword(password, stored) {
  if (!stored?.salt || !stored?.hash) return false;
  const hash = scryptSync(String(password), stored.salt, 32);
  const prev = Buffer.from(stored.hash, "hex");
  if (prev.length !== hash.length) return false;
  return timingSafeEqual(prev, hash);
}

function demoNodes() {
  const probe = (host, port = 443) => ({ probeHost: host, probePort: port, alpha: true, online: true });
  return [
    {
      id: "nl-trojan",
      name: "Нидерланды Trojan",
      protocol: "trojan",
      country: "nl",
      flag: "nl",
      until: "2027-02-21",
      ...probe("1.1.1.1"),
    },
    {
      id: "nl-vless",
      name: "Нидерланды VLESS XHTTP",
      protocol: "vless",
      transport: "xhttp",
      country: "nl",
      flag: "nl",
      until: "2027-02-12",
      ...probe("1.0.0.1"),
    },
    {
      id: "smart-hy",
      name: "Умная локация Hysteria",
      protocol: "hysteria2",
      country: "auto",
      flag: "auto",
      until: "2027-02-10",
      ...probe("8.8.8.8"),
    },
    {
      id: "nl-hy",
      name: "Нидерланды HYSTERIA",
      protocol: "hysteria2",
      country: "nl",
      flag: "nl",
      until: "2027-02-21",
      ...probe("9.9.9.9"),
    },
    {
      id: "smart",
      name: "Умная локация",
      protocol: "vless",
      country: "auto",
      flag: "auto",
      until: "2027-02-09",
      ...probe("1.1.1.1"),
    },
    {
      id: "direct",
      name: "Без VPN",
      protocol: "direct",
      country: "",
      flag: "direct",
      until: "",
      online: true,
      alpha: true,
    },
  ];
}

function demoDevices() {
  const row = (partial) => ({
    online: true,
    isNew: false,
    excluded: false,
    route: "default",
    bypass: [],
    traffic: { session: 0, today: 0, d7: 0, d30: 0 },
    demo: true,
    ...partial,
  });
  return [
    row({ id: "d1", name: "Гостиная", ip: "192.168.50.21", mac: "F4:34:F0:4F:1D:11" }),
    row({ id: "d2", name: "Телевизор", ip: "192.168.50.32", mac: "F4:34:F0:38:F7:22" }),
    row({ id: "d3", name: "Ноутбук", ip: "192.168.50.44", mac: "00:11:32:9F:E6:33" }),
    row({ id: "d4", name: "Телефон", ip: "192.168.50.51", mac: "B4:55:75:4C:6B:44", excluded: true }),
    row({ id: "d5", name: "Рабочий стол", ip: "192.168.50.60", mac: "16:1B:E7:DD:E6:55" }),
    row({ id: "d6", name: "Пылесос", ip: "192.168.50.71", mac: "B0:4A:39:F8:E4:66" }),
    row({ id: "d7", name: "Точка AX", ip: "192.168.50.2", mac: "D4:5D:64:A0:37:77" }),
    row({ id: "d8", name: "Планшет", ip: "192.168.50.80", mac: "6C:70:CB:89:50:88" }),
    row({ id: "d9", name: "Спальня", ip: "192.168.50.90", mac: "A4:61:AB:1A:E8:99" }),
    row({ id: "d10", name: "Часы", ip: "192.168.50.101", mac: "72:A3:B5:11:28:AA", isNew: true }),
    row({ id: "d11", name: "Камера", ip: "192.168.50.110", mac: "90:EB:48:22:AD:BB" }),
  ];
}

export function defaultState() {
  const memGb = Math.max(1, Math.round(totalmem() / 1024 / 1024 / 1024));
  return {
    version: VERSION,
    createdAt: Date.now(),
    password: hashPassword("alfa"),
    failedLogins: 0,
    lockedUntil: 0,
    sessions: {},
    routerId: randomUUID(),
    account: {
      email: "",
      balance: 0,
      subscriptionName: "Основная подписка",
      nextCharge: "",
      consoleUrl: "",
      consoleConnected: false,
      inviteCode: "",
    },
    vpn: {
      connected: false,
      directMode: false,
      since: null,
      selectedId: "nl-trojan",
      lastVpnId: "nl-trojan",
      autoSetupToggle: false,
      exitIp: "",
      exitCountry: "",
    },
    subscriptions: [
      { id: "main", name: "Основная", url: "", builtin: true, nodes: demoNodes() },
    ],
    activeSubscription: "main",
    router: {
      mode: "except",
      dnsViaVpn: true,
      blockQuic: false,
      dnsLock: true,
      gamesDirect: false,
      blockWithoutVpn: false,
      ipv6: "block",
      adblock: true,
      adCustom: [],
      adWhitelist: [],
      adExcludeDevices: [],
      adStats: { today: 0, week: 0, recent: [], top: {} },
      trips: false,
      captive: false,
      ha: false,
      mqtt: { host: "", port: 1883, username: "", password: "", status: "" },
      scheduleEnabled: false,
      scheduleHours: hoursOn(),
      reserveId: "",
    },
    devices: demoDevices(),
    dismissedNew: [],
    routing: {
      source: "server",
      localDirty: false,
      appliedLocal: true,
      clientSide: true,
      autoSelect: false,
      balancers: [],
      excludeRu: true,
      whitelist: true,
      twitch: false,
      spotify: false,
      lan: true,
      androidAuto: false,
      bittorrent: true,
      games: true,
      blockQuic: false,
      blockAds: true,
      blockPorn: false,
      fragment: false,
      custom: [],
      dnsProvider: "cloudflare",
      dnsFallback: "google",
      perConfig: {},
    },
    configRoutes: {},
    profiles: [],
    network: {
      youtubeZapret: false,
      discordZapret: false,
      telegramDirect: true,
      zapret: {
        lists: [],
        methods: [],
        lastCheck: null,
        checking: false,
        serviceWays: {},
      },
    },
    connection: {
      onBoot: true,
      onSelect: true,
      ipv4Only: false,
      shareLan: false,
      warpMode: "off",
      warpMethod: "auto",
      warpProfile: null,
      mux: "subscription",
      muxConcurrency: 8,
      bridges: [],
    },
    automode: { configId: "", enabled: false, log: [] },
    netAuto: {
      enabled: false,
      current: "ethernet",
      rules: { default: "", ethernet: "", lte: "" },
    },
    engine: {
      preference: "auto",
      active: null,
      activeReason: "",
      domainStrategy: "auto",
      fakeIp: false,
      socksPort: 20808,
      httpPort: 20809,
      geoSource: "standard",
      geoUrl: "",
      geo: { geosite: 0, geoip: 0, updatedAt: null },
      cores: {},
    },
    appearance: {
      theme: "dark",
      accent: "stealth",
      icon: "base",
      oled: true,
    },
    other: {
      autoSetup: true,
      showAutoToggle: true,
      liveButton: true,
      speedChart: true,
      showPing: true,
    },
    updates: {
      auto: true,
      windowStart: 2,
      windowEnd: 5,
      geoWeekly: true,
      coresWhenMissing: true,
      interval: "6h",
      lastCheck: null,
      latest: VERSION,
      note: "Альфа собрана локально и не ставится поверх прошивки сама.",
    },
    diagnostics: {
      showLoad: true,
      devMode: false,
      errorReports: true,
      tunnelCheck: true,
      mtu: 1500,
      stack: "mixed",
      logLevel: "warning",
    },
    logs: [],
    feedback: [],
    about: {
      model: hostname(),
      firmware: `${platform()} / стенд альфы`,
      memory: `${memGb} ГБ`,
      arch: arch(),
      referenceModel: "ASUS RT-BE88U",
      referenceFirmware: "Asuswrt-Merlin 3006.102.9",
      referenceArch: "aarch64",
      referencePanel: "http://192.168.50.1:8800",
    },
    pings: {},
    wasConnected: false,
  };
}

export function loadState() {
  mkdirSync(DATA, { recursive: true });
  if (!existsSync(STATE_PATH)) {
    const state = defaultState();
    saveState(state);
    return state;
  }
  try {
    const parsed = JSON.parse(readFileSync(STATE_PATH, "utf8"));
    return mergeDefaults(defaultState(), parsed);
  } catch {
    const broken = `${STATE_PATH}.broken-${Date.now()}`;
    try { renameSync(STATE_PATH, broken); } catch { /* ignore */ }
    const state = defaultState();
    saveState(state);
    return state;
  }
}

function mergeDefaults(base, extra) {
  if (Array.isArray(base)) return Array.isArray(extra) ? extra : base;
  if (base && typeof base === "object") {
    const out = { ...base };
    if (extra && typeof extra === "object" && !Array.isArray(extra)) {
      for (const key of Object.keys(extra)) {
        out[key] = key in base ? mergeDefaults(base[key], extra[key]) : extra[key];
      }
    }
    return out;
  }
  return extra === undefined ? base : extra;
}

let saveTimer = null;
let pending = null;

export function saveState(state, immediate = false) {
  pending = state;
  if (immediate) {
    if (saveTimer) clearTimeout(saveTimer);
    saveTimer = null;
    flush();
    return;
  }
  if (saveTimer) return;
  saveTimer = setTimeout(flush, 150);
}

function flush() {
  saveTimer = null;
  if (!pending) return;
  mkdirSync(dirname(STATE_PATH), { recursive: true });
  const copy = structuredClone(pending);
  const tmp = `${STATE_PATH}.tmp`;
  writeFileSync(tmp, JSON.stringify(copy, null, 2));
  renameSync(tmp, STATE_PATH);
}

export function publicState(state, runtime = {}) {
  const { password, sessions, failedLogins, lockedUntil, ...rest } = state;
  return {
    ...rest,
    passwordSet: Boolean(password?.hash),
    runtime,
  };
}

export function findNode(state, id = state.vpn.selectedId) {
  for (const sub of state.subscriptions) {
    const node = sub.nodes.find((n) => n.id === id);
    if (node) return { node, subscription: sub };
  }
  return { node: null, subscription: null };
}

export function visibleNodes(state, engineId) {
  const sub = state.subscriptions.find((s) => s.id === state.activeSubscription) || state.subscriptions[0];
  const pref = engineId || state.engine.preference;
  return (sub?.nodes || []).filter((node) => {
    if (node.protocol === "direct") return true;
    if (pref === "auto") return true;
    return engineSupports(pref, node.protocol);
  });
}

export function appendLog(state, level, msg) {
  state.logs.unshift({ t: Date.now(), level, msg: String(msg).slice(0, 2000) });
  if (state.logs.length > 400) state.logs.length = 400;
}

export function setPath(obj, path, value) {
  const parts = String(path).split(".").filter(Boolean);
  if (!parts.length) throw new Error("Пустой путь");
  let cur = obj;
  for (let i = 0; i < parts.length - 1; i++) {
    const key = parts[i];
    if (!cur[key] || typeof cur[key] !== "object") cur[key] = {};
    cur = cur[key];
  }
  cur[parts.at(-1)] = value;
}

const PATCH_ROOTS = new Set([
  "router",
  "routing",
  "network",
  "connection",
  "automode",
  "netAuto",
  "engine",
  "appearance",
  "other",
  "updates",
  "diagnostics",
  "account",
  "vpn",
]);

export function assertPatch(path) {
  const root = String(path).split(".")[0];
  if (!PATCH_ROOTS.has(root)) throw new Error("Это поле нельзя менять напрямую");
  if (path === "vpn.connected" || path.startsWith("account.balance")) {
    throw new Error("Это поле меняется отдельной командой");
  }
}
