/**
 * EngVPN panel extensions mixed into the vendored alfa runtime at build time.
 * Open components only — shells out to engvpnd / transparent.sh / update.sh.
 */
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { existsSync, readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

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

export async function engvpnTransparent(command, body = {}) {
  if (body && typeof body === "object") {
    const patch = {};
    if (body.mode) patch.mode = body.mode;
    if (body.method) patch.method = body.method;
    if (body.port) patch.port = String(body.port);
    if (body.killswitch != null) patch.killswitch = body.killswitch ? "1" : "0";
    if (body.routerMode) patch.mode = modeFromRouter(body.routerMode);
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
