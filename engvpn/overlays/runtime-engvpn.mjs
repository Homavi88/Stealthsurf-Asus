/**
 * EngVPN panel extensions mixed into the vendored alfa runtime at build time.
 * Open components only — shells out to engvpnd / transparent.sh / update.sh.
 * Also maps StealthSurf-style invoke names onto EngVPN state / daemon.
 */
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { existsSync, readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { hostname, totalmem, freemem, arch, platform, cpus, loadavg } from "node:os";

const exec = promisify(execFile);
const LIB = dirname(fileURLToPath(import.meta.url));
const RUNTIME_ROOT = join(LIB, ".."); // <prefix>/share/engvpn/runtime
const SHARE = join(RUNTIME_ROOT, ".."); // <prefix>/share/engvpn
const ENGVPN_PREFIX = join(SHARE, "..", ".."); // <prefix>
const ENGVPND = join(ENGVPN_PREFIX, "sbin", "engvpnd");
const DATA = process.env.ENGVPN_DATA_DIR || join(ENGVPN_PREFIX, "data");

async function shEngvpnd(...args) {
  const bin = existsSync(ENGVPND) ? ENGVPND : "engvpnd";
  const { stdout, stderr } = await exec(bin, args, {
    env: { ...process.env, ENGVPN_DATA_DIR: process.env.ENGVPN_DATA_DIR || DATA },
    timeout: 120000,
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
  const body = Object.entries(next)
    .map(([k, v]) => `${k}=${v}`)
    .join("\n");
  writeFileSync(path, `${body}\n`, { mode: 0o600 });
  return next;
}

/** Map panel router.mode → transparent.conf mode */
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

/** Map transparent / SS transparentMode → panel router.mode */
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
    if (out.current || out.version) parts.push(`текущая ${out.current || out.version}`);
    if (out.latest) parts.push(`в feed ${out.latest}`);
    if (out.update === "1" || out.available === "1") parts.push("доступно обновление");
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

function loadAvgCpuPct() {
  try {
    const la = loadavg()[0] || 0;
    const n = Math.max(1, cpus()?.length || 1);
    return Math.min(100, Math.round((la / n) * 100));
  } catch {
    return 0;
  }
}

/** StealthSurf-shaped get_* helpers backed by EngVPN panel state + daemon. */
export function engvpnParityInvoke(command, body, state, snapshotFn) {
  const snap = typeof snapshotFn === "function" ? snapshotFn() : state;
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
          telegramDirect: true,
          smartDns: false,
          lanProxyServer: true,
          warp: false,
          gaming: false,
          tray: false,
          cloudAccount: false,
        },
        engines: ["auto", "xray", "sing-box", "mihomo"],
        note: "Ferrum и облако StealthSurf не поставляются",
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
        email: state.account?.email || "",
        subscriptionName: state.account?.subscriptionName || "Локальные подписки",
        cloud: false,
        stub: "Облако StealthSurf не подключено",
        balance: null,
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
      return state.network?.zapret || {};
    case "get_telegram_direct_status":
      return { enabled: !!state.network?.telegramDirect, ready: !!state.network?.telegramDirect };
    case "get_smart_dns_bypass":
      return { enabled: false, stub: true, note: "SmartDNS / сервисы без VPN консоли StealthSurf не клонированы" };
    case "get_stored_cores":
      return state.runtime?.cores || state.engine?.cores || {};
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
        });
      }
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
    default:
      return undefined;
  }
}
