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
fs.copyFileSync(join(root, "src", "ui", "index.asp"), join(dist, "index.asp"));
fs.copyFileSync(join(root, "src", "ui", "app.js"), join(dist, "app.js"));

console.log("Built dist/stealthsurf, dist/index.asp, dist/app.js");
console.log(`Shell size: ${merged.length} bytes`);
