import fs from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const root = join(__dirname, "..");
const dist = join(root, "dist");

function inlineShellImports(scriptPath, visited = new Set(), isRoot = true) {
  if (visited.has(scriptPath)) return "";
  visited.add(scriptPath);

  const content = fs.readFileSync(scriptPath, "utf8").replaceAll("\r\n", "\n");
  const dirOfScript = dirname(scriptPath);
  let output = "";

  for (const line of content.split("\n")) {
    const match = line.match(/^import\s+(.+)$/);
    if (match) {
      output += inlineShellImports(resolve(dirOfScript, match[1].trim()), visited, false);
    } else if (!(!isRoot && /^#/.test(line))) {
      output += `${line}\n`;
    }
  }
  return output;
}

fs.rmSync(dist, { recursive: true, force: true });
fs.mkdirSync(dist, { recursive: true });

const merged = inlineShellImports(join(root, "src", "backend", "stealthsurf.sh"));
fs.writeFileSync(join(dist, "stealthsurf"), merged, { mode: 0o755 });

const pkg = JSON.parse(fs.readFileSync(join(root, "package.json"), "utf8"));
const ver = String(pkg.version || "0");
let indexAsp = fs.readFileSync(join(root, "src", "ui", "index.asp"), "utf8");
indexAsp = indexAsp.replaceAll("__SS_VERSION__", ver);
fs.writeFileSync(join(dist, "index.asp"), indexAsp);
fs.copyFileSync(join(root, "src", "ui", "app.js"), join(dist, "app.js"));
fs.copyFileSync(join(root, "src", "ui", "routing-suggest.js"), join(dist, "routing-suggest.js"));

console.log("Built dist/stealthsurf, dist/index.asp, dist/app.js, dist/routing-suggest.js");
console.log(`Shell size: ${merged.length} bytes; UI cache-bust v=${ver}`);
