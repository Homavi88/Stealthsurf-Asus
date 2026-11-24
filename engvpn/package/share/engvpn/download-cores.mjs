#!/usr/bin/env node
/**
 * Download EngVPN engine cores + geo DBs after install/upgrade.
 *
 *   node download-cores.mjs [--data-dir DIR] [--prefix DIR]
 *
 * Progress goes to stdout (OK for terminal install). Soft-fail: exit 0 even if
 * some cores fail (panel can retry). ENGVPN_SKIP_CORES=1 skips entirely.
 */
import { existsSync, mkdirSync, writeFileSync, statSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const SHARE = dirname(fileURLToPath(import.meta.url));
const PREFIX_DEFAULT = join(SHARE, "..", "..");

function arg(name, fallback = "") {
  const i = process.argv.indexOf(name);
  return i >= 0 ? (process.argv[i + 1] || fallback) : fallback;
}

if (process.env.ENGVPN_SKIP_CORES === "1") {
  console.log("download-cores: skipped (ENGVPN_SKIP_CORES=1)");
  process.exit(0);
}
// Smoke installs stay offline unless explicitly requested.
if (process.env.ENGVPN_SMOKE === "1" && process.env.ENGVPN_FETCH_CORES !== "1") {
  console.log("download-cores: skipped (smoke; set ENGVPN_FETCH_CORES=1 to force)");
  process.exit(0);
}

const prefix = arg("--prefix", process.env.ENGVPN_PREFIX || PREFIX_DEFAULT);
const dataDir = arg("--data-dir", process.env.ENGVPN_DATA_DIR || join(prefix, "data"));
process.env.ENGVPN_DATA_DIR = dataDir;
mkdirSync(dataDir, { recursive: true });
mkdirSync(join(dataDir, "cores"), { recursive: true });
mkdirSync(join(dataDir, "geo"), { recursive: true });

const enginesUrl = pathToFileURL(join(SHARE, "runtime/lib/engines.mjs")).href;
const { downloadCore, GEO_DIR, CORE_DIR } = await import(enginesUrl);

// GEO_DIR comes from engines (runtime/data/geo) — may differ from dataDir/geo above.
const geoDir = GEO_DIR || join(dataDir, "geo");
mkdirSync(geoDir, { recursive: true });
if (CORE_DIR) mkdirSync(CORE_DIR, { recursive: true });

const CORES = ["xray", "ferrum", "sing-box", "mihomo"];
const GEO_BASE = "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download";

function fmtBytes(n) {
  const v = Number(n) || 0;
  if (v < 1024) return `${v} Б`;
  if (v < 1024 * 1024) return `${(v / 1024).toFixed(1)} КБ`;
  return `${(v / 1024 / 1024).toFixed(1)} МБ`;
}

function progressLine(info) {
  if (typeof info === "string") return info;
  if (!info || typeof info !== "object") return "";
  const bits = [];
  if (info.phase) bits.push(info.phase === "install" ? "установка" : info.phase === "lookup" ? "поиск" : "скачивание");
  if (info.label) bits.push(info.label);
  if (info.total > 0) {
    bits.push(`${fmtBytes(info.received || 0)} / ${fmtBytes(info.total)}`);
    if (info.percent != null) bits.push(`${info.percent}%`);
  } else if (info.received > 0) {
    bits.push(fmtBytes(info.received));
  }
  return bits.filter(Boolean).join(" · ");
}

async function downloadGeo(name) {
  const url = `${GEO_BASE}/${name}`;
  const dest = join(geoDir, name);
  mkdirSync(dirname(dest), { recursive: true });
  console.log(`  → geo ${name}…`);
  const response = await fetch(url, {
    signal: AbortSignal.timeout(120_000),
    headers: { "User-Agent": "engvpn" },
    redirect: "follow",
  });
  if (!response.ok) throw new Error(`${name}: HTTP ${response.status}`);
  const total = Number(response.headers.get("content-length")) || 0;
  if (!response.body || typeof response.body.getReader !== "function") {
    const buf = Buffer.from(await response.arrayBuffer());
    writeFileSync(dest, buf);
    console.log(`  → geo ${name}: ${fmtBytes(buf.length)}`);
    return buf.length;
  }
  const reader = response.body.getReader();
  const chunks = [];
  let received = 0;
  let lastPct = -1;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    chunks.push(Buffer.from(value));
    received += value.byteLength;
    if (total > 0) {
      const pct = Math.min(99, Math.floor((received / total) * 100));
      if (pct >= lastPct + 5 || received === total) {
        lastPct = pct;
        process.stdout.write(`\r  → geo ${name}: ${pct}% (${fmtBytes(received)} / ${fmtBytes(total)})   `);
      }
    } else if (received % (512 * 1024) < value.byteLength) {
      process.stdout.write(`\r  → geo ${name}: ${fmtBytes(received)}   `);
    }
  }
  const buf = Buffer.concat(chunks);
  writeFileSync(dest, buf);
  process.stdout.write(`\r  → geo ${name}: ${fmtBytes(buf.length)}${" ".repeat(24)}\n`);
  return buf.length;
}

let failed = 0;
console.log(`download-cores: data=${dataDir}`);
for (const id of CORES) {
  console.log(`  → ядро ${id}…`);
  let last = "";
  try {
    const result = await downloadCore(id, (info) => {
      const line = progressLine(info);
      if (!line || line === last) return;
      last = line;
      if (typeof info === "object" && info?.total > 0) {
        process.stdout.write(`\r  → ${id}: ${line}   `);
      } else {
        console.log(`  → ${id}: ${line}`);
      }
    });
    process.stdout.write("\r");
    console.log(`  → ${id}: готово ${result?.version || ""} (${fmtBytes(result?.bytes || 0)})`);
  } catch (err) {
    failed += 1;
    process.stdout.write("\r");
    console.log(`  → ${id}: ошибка — ${err.message || err}`);
  }
}

try {
  const geosite = await downloadGeo("geosite.dat");
  const geoip = await downloadGeo("geoip.dat");
  console.log(`download-cores: geo ok (geosite ${fmtBytes(geosite)}, geoip ${fmtBytes(geoip)})`);
} catch (err) {
  failed += 1;
  console.log(`download-cores: geo ошибка — ${err.message || err}`);
}

const coreDir = CORE_DIR || join(dataDir, "cores");
const present = CORES.filter((id) => {
  try {
    const bin = id === "sing-box" ? "sing-box" : id === "mihomo" ? "mihomo" : id === "ferrum" ? "ferrum" : "xray";
    const p = join(coreDir, bin);
    return existsSync(p) && statSync(p).size > 0;
  } catch {
    return false;
  }
});
console.log(`download-cores: cores present ${present.length}/${CORES.length}${failed ? ` (failures=${failed})` : ""}`);
process.exit(0);
