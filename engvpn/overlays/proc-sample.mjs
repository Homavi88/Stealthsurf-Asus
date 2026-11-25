#!/usr/bin/env node
/**
 * EngVPN Diagnostics — isolated /proc top-N sampler.
 *
 * Short-lived child of the panel so a Merlin aarch64 Entware Node V8 Fatal
 * (DiscardSystemPages / concurrent sweeper, exit 133) cannot kill HTTP.
 * Tiny heap: cap PIDs, cmdline only for top-N, no giant arrays.
 *
 * Usage: node [gc-flags…] proc-sample.mjs [limit]
 * stdout: JSON { byCpu, byRam, flagged, hints, source, at, count }
 */
import { readdirSync, readFileSync, writeFileSync } from "node:fs";

const limit = Math.min(16, Math.max(1, Number(process.argv[2]) || 8));
const PROC_CAP = 64;
const CMDLINE_CAP = Math.min(20, Math.max(limit * 2, 12));

function empty(at, source = "none") {
  return { byCpu: [], byRam: [], flagged: [], hints: [], source, at, count: 0 };
}

function readTotalCpuJiffies() {
  try {
    const line = String(readFileSync("/proc/stat", "utf8") || "").split("\n")[0] || "";
    const parts = line.trim().split(/\s+/).slice(1);
    let sum = 0;
    for (const p of parts) sum += Number(p) || 0;
    return sum;
  } catch {
    return 0;
  }
}

function parsePidStat(pid) {
  try {
    const text = readFileSync(`/proc/${pid}/stat`, "utf8");
    const open = text.indexOf("(");
    const close = text.lastIndexOf(")");
    if (open < 0 || close < open) return null;
    const name = text.slice(open + 1, close);
    const rest = text.slice(close + 2).trim().split(/\s+/);
    return {
      pid: Number(pid),
      name,
      ticks: (Number(rest[11]) || 0) + (Number(rest[12]) || 0),
    };
  } catch {
    return null;
  }
}

function readPidRssKb(pid) {
  try {
    const text = readFileSync(`/proc/${pid}/status`, "utf8");
    const m = text.match(/^VmRSS:\s+(\d+)/m);
    return m ? Number(m[1]) || 0 : 0;
  } catch {
    return 0;
  }
}

function readPidCmdline(pid) {
  try {
    const buf = readFileSync(`/proc/${pid}/cmdline`);
    const slice = buf.length > 256 ? buf.subarray(0, 256) : buf;
    return slice.toString("utf8").replace(/\0+/g, " ").trim();
  } catch {
    return "";
  }
}

function shortCmdName(cmd, fallback) {
  if (!cmd) return String(fallback || "").slice(0, 40);
  const first = cmd.split(/\s+/)[0] || fallback || "";
  const base = first.includes("/") ? first.slice(first.lastIndexOf("/") + 1) : first;
  return (base || fallback || "").slice(0, 40);
}

function classify(name, cmdline) {
  const s = `${name || ""} ${cmdline || ""}`.toLowerCase();
  if (/share\/engvpn\/service\.sh|\/engvpn\/share\/engvpn\/service\.sh/.test(s)) {
    return { kind: "supervisor", label: "service" };
  }
  if (/(?:^|\s|\/)sleep(?:\s|$)/.test(s) && /engvpn|ENGVPN_/.test(s)) {
    return { kind: "orphan", label: "sleep" };
  }
  if (/runtime\/run\.mjs|engvpn-panel/.test(s)) return { kind: "node", label: "panel" };
  if (/engvpnd/.test(s)) return { kind: "engvpn", label: "engvpnd" };
  if (/\/engvpn\//.test(s) || /share\/engvpn/.test(s)) return { kind: "engvpn", label: "engvpn" };
  if (/\bxray\b/.test(s) || /\/cores\/xray\b/.test(s) || /\/ferrum\b/.test(s)) {
    return { kind: "core", label: /ferrum/.test(s) ? "ferrum" : "xray" };
  }
  if (/sing-box|singbox/.test(s)) return { kind: "core", label: "sing-box" };
  if (/\bmihomo\b|\bclash\b/.test(s)) return { kind: "core", label: "mihomo" };
  if (/\bnode\b/.test(s) || /\/node\b/.test(s)) return { kind: "node", label: "node" };
  return { kind: "", label: "" };
}

const at = Date.now();
const totalNow = readTotalCpuJiffies();
let entries;
try {
  entries = readdirSync("/proc");
} catch {
  process.stdout.write(JSON.stringify(empty(at)));
  process.exit(0);
}

const raw = [];
let listed = 0;
for (const ent of entries) {
  if (!/^\d+$/.test(ent)) continue;
  listed += 1;
  if (listed > PROC_CAP * 3) break;
  if (raw.length >= PROC_CAP) break;
  const st = parsePidStat(ent);
  if (!st) continue;
  const rssKb = readPidRssKb(ent);
  if (rssKb <= 0 && st.ticks <= 0) continue;
  raw.push({ pid: st.pid, name: st.name, ticks: st.ticks, rssKb });
}

raw.sort((a, b) => b.rssKb - a.rssKb || b.ticks - a.ticks);
const top = raw.slice(0, CMDLINE_CAP);

const prevPath = process.env.ENGVPN_PROC_SNAP || "";
let prev = null;
if (prevPath) {
  try {
    prev = JSON.parse(readFileSync(prevPath, "utf8"));
  } catch {
    prev = null;
  }
}

const rows = [];
const nextByPid = Object.create(null);
for (const t of top) {
  nextByPid[t.pid] = t.ticks;
  let cpu = 0;
  if (prev && prev.totalJiffies > 0 && totalNow > prev.totalJiffies) {
    const prevTicks = prev.byPid?.[t.pid];
    if (prevTicks != null) {
      const dProc = Math.max(0, t.ticks - prevTicks);
      const dTot = totalNow - prev.totalJiffies;
      if (dTot > 0) cpu = Math.min(100, (dProc / dTot) * 100);
    }
  }
  const cmdline = readPidCmdline(t.pid);
  const name = shortCmdName(cmdline, t.name) || t.name || String(t.pid);
  const cls = classify(name, cmdline || t.name);
  rows.push({
    pid: t.pid,
    name,
    cpu: Math.round(cpu * 10) / 10,
    rss: t.rssKb * 1024,
    rssKb: t.rssKb,
    kind: cls.kind || undefined,
    label: cls.label || undefined,
    flag: !!cls.kind,
  });
}

if (prevPath) {
  try {
    writeFileSync(prevPath, JSON.stringify({ totalJiffies: totalNow, byPid: nextByPid }), {
      mode: 0o600,
    });
  } catch {
    /* ignore */
  }
}

const flagged = rows.filter((r) => r.flag).sort((a, b) => b.cpu - a.cpu || b.rss - a.rss);
const pin = (list) => {
  const seen = new Set(list.map((r) => r.pid));
  const out = list.slice();
  for (const f of flagged) {
    if (seen.has(f.pid)) continue;
    out.push(f);
    seen.add(f.pid);
  }
  return out.slice(0, Math.max(limit, Math.min(limit + flagged.length, 16)));
};

const byCpu = pin(rows.slice().sort((a, b) => b.cpu - a.cpu || b.rss - a.rss).slice(0, limit));
const byRam = pin(rows.slice().sort((a, b) => b.rss - a.rss || b.cpu - a.cpu).slice(0, limit));

process.stdout.write(
  JSON.stringify({
    byCpu,
    byRam,
    flagged,
    hints: [],
    source: "proc-child",
    at,
    count: raw.length,
  }),
);
