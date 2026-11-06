#!/usr/bin/env node
/**
 * Build a Merlin-stubbed StealthSurf UI preview and capture GitHub README screenshots.
 * Usage: node tools/capture-ui-screenshots.mjs
 */
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";
import * as mock from "./ui-preview/mock-data.mjs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, "..");
const PREVIEW = path.join(ROOT, "tools/ui-preview");
const EXT = path.join(PREVIEW, "ext/stealthsurf");
const OUT = path.join(ROOT, "docs/screenshots");
const PORT = 8765;

fs.mkdirSync(EXT, { recursive: true });
fs.mkdirSync(OUT, { recursive: true });

function writeJson(name, data) {
  fs.writeFileSync(path.join(EXT, name), JSON.stringify(data, null, 2));
}

function buildIndex(variant = "running") {
  let html = fs.readFileSync(path.join(ROOT, "src/ui/index.asp"), "utf8");
  // Strip ASP / firmware includes
  html = html
    .replace(/<%[\s\S]*?%>/g, "")
    .replace(/<xmp[\s\S]*?<\/xmp>/gi, "")
    .replace(/href="index_style\.css"/, 'href="/merlin-stub.css"')
    .replace(/href="form_style\.css"/, 'href="/merlin-stub.css"')
    .replace(/href="menu_style\.css"/, 'href="/merlin-stub.css"')
    .replace(/href="\/js\/table\/table\.css"/, 'href="/merlin-stub.css"')
    .replace(/<script[^>]+src="\/js\/[^"]+"><\/script>\s*/g, "")
    .replace(/<script[^>]+src="\/state\.js"><\/script>\s*/g, "")
    .replace(/<script[^>]+src="\/general\.js"><\/script>\s*/g, "")
    .replace(/<script[^>]+src="\/popup\.js"><\/script>\s*/g, "")
    .replace(/<script[^>]+src="\/help\.js"><\/script>\s*/g, "")
    .replace(/<script[^>]+src="\/validator\.js"><\/script>\s*/g, "");

  const inject = `
<link rel="stylesheet" type="text/css" href="/merlin-stub.css">
<script>
var custom_settings = {};
function show_menu() {
  var m = document.getElementById("mainMenu");
  if (!m) return;
  m.innerHTML = [
    '<a class="mm" href="#">Network Map</a>',
    '<a class="mm" href="#">Guest Network</a>',
    '<a class="mm" href="#">AIProtection</a>',
    '<a class="mm" href="#">Traffic Analyzer</a>',
    '<a class="mm" href="#">Adaptive QoS</a>',
    '<a class="mm active" href="#">VPN</a>',
    '<a class="mm" href="#">Firewall</a>',
    '<a class="mm" href="#">LAN</a>',
    '<a class="mm" href="#">WAN</a>',
    '<a class="mm" href="#">System</a>'
  ].join("");
  var t = document.getElementById("tabMenu");
  if (t) t.textContent = "VPN › StealthSurf";
  var b = document.getElementById("TopBanner");
  if (b) b.innerHTML = 'ASUS Wireless Router <small>RT-AX88U · Merlin · preview</small>';
  var f = document.getElementById("footer");
  if (f) f.textContent = "StealthSurf UI preview for GitHub screenshots";
}
function showLoading() {}
window.addEventListener("DOMContentLoaded", function () {
  show_menu();
  var params = new URLSearchParams(location.search);
  var tab = params.get("tab");
  var conflict = params.get("conflict") === "1";
  if (conflict) {
    fetch("/ext/stealthsurf/state-conflict.json").then(function (r) { return r.json(); }).then(function (s) {
      if (typeof renderState === "function") renderState(s);
    }).catch(function () {});
  }
  if (tab && typeof switchTab === "function") {
    setTimeout(function () { switchTab(tab); }, 250);
  }
});
</script>
<div class="preview-badge">GitHub preview · not live router</div>
`;
  html = html.replace("</head>", inject + "\n</head>");
  // Copy app.js
  fs.copyFileSync(path.join(ROOT, "src/ui/app.js"), path.join(EXT, "app.js"));
  fs.writeFileSync(path.join(PREVIEW, "index.html"), html);
  return variant;
}

writeJson("state.json", mock.state);
writeJson("state-conflict.json", mock.stateConflict);
writeJson("configs.json", mock.configs);
writeJson("locations.json", mock.locations);
writeJson("subscriptions.json", mock.subscriptions);
writeJson("api_keys.json", mock.api_keys);
writeJson("outbounds.json", mock.outbounds);
writeJson("routing.json", mock.routing);
writeJson("policies.json", mock.policies);
writeJson("version.json", mock.version);
writeJson("protocols.json", mock.protocols);
writeJson("stealthsurf-response.json", mock.response);
writeJson("backups.json", []);
fs.copyFileSync(path.join(PREVIEW, "merlin-stub.css"), path.join(PREVIEW, "merlin-stub.css"));
buildIndex();

function contentType(p) {
  if (p.endsWith(".html")) return "text/html; charset=utf-8";
  if (p.endsWith(".js")) return "application/javascript; charset=utf-8";
  if (p.endsWith(".css")) return "text/css; charset=utf-8";
  if (p.endsWith(".json")) return "application/json; charset=utf-8";
  return "application/octet-stream";
}

const server = http.createServer((req, res) => {
  const url = decodeURIComponent((req.url || "/").split("?")[0]);
  let file = path.join(PREVIEW, url === "/" ? "index.html" : url);
  if (!file.startsWith(PREVIEW)) {
    res.writeHead(403);
    res.end("forbidden");
    return;
  }
  if (!fs.existsSync(file) || fs.statSync(file).isDirectory()) {
    res.writeHead(404);
    res.end("not found " + url);
    return;
  }
  res.writeHead(200, { "Content-Type": contentType(file), "Cache-Control": "no-store" });
  res.end(fs.readFileSync(file));
});

await new Promise((resolve) => server.listen(PORT, "127.0.0.1", resolve));
console.log("Preview http://127.0.0.1:" + PORT);

async function loadPuppeteer() {
  try {
    return await import("puppeteer-core");
  } catch {
    console.log("Installing puppeteer-core…");
    await new Promise((resolve, reject) => {
      const p = spawn("npm", ["install", "--no-save", "puppeteer-core@24"], {
        cwd: ROOT,
        stdio: "inherit",
      });
      p.on("exit", (code) => (code === 0 ? resolve() : reject(new Error("npm install failed"))));
    });
    return import("puppeteer-core");
  }
}

const puppeteer = await loadPuppeteer();
const browser = await puppeteer.default.launch({
  executablePath: "/usr/local/bin/google-chrome",
  headless: "new",
  args: ["--no-sandbox", "--disable-gpu", "--window-size=1400,1000"],
  defaultViewport: { width: 1400, height: 1000, deviceScaleFactor: 1 },
});

const shots = [
  { file: "01-status-running.png", path: "/?tab=keys", wait: 900, state: "running" },
  { file: "02-catalog.png", path: "/?tab=catalog", wait: 1000, state: "running" },
  { file: "03-routing.png", path: "/?tab=routing", wait: 1000, state: "running" },
  { file: "04-mode-dns.png", path: "/?tab=general", wait: 1000, state: "running" },
  { file: "05-xrayui-conflict.png", path: "/?tab=keys", wait: 1100, state: "conflict" },
];

const page = await browser.newPage();
for (const shot of shots) {
  writeJson("state.json", shot.state === "conflict" ? mock.stateConflict : mock.state);
  const url = `http://127.0.0.1:${PORT}${shot.path}`;
  console.log("Capture", shot.file, url);
  await page.goto(url, { waitUntil: "networkidle0", timeout: 30000 });
  await page.waitForSelector("#runState", { timeout: 10000 });
  await new Promise((r) => setTimeout(r, shot.wait));
  // Ensure requested tab is active even if refresh raced
  const tab = new URL(url).searchParams.get("tab");
  if (tab) {
    await page.evaluate((t) => {
      if (typeof switchTab === "function") switchTab(t);
    }, tab);
    await new Promise((r) => setTimeout(r, 200));
  }
  const out = path.join(OUT, shot.file);
  await page.screenshot({ path: out, fullPage: false });
  console.log("Wrote", out, fs.statSync(out).size, "bytes");
}
// restore running mock
writeJson("state.json", mock.state);

await browser.close();
server.close();
console.log("Done. Screenshots in docs/screenshots/");
