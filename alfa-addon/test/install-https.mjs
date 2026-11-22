import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, chmodSync, readFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { spawnSync, execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { gunzipSync } from "node:zlib";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const installSh = join(root, "install.sh");

test("install.sh is valid busybox/ash shell", () => {
  const checked = spawnSync("sh", ["-n", installSh], { encoding: "utf8" });
  assert.equal(checked.status, 0, checked.stderr);
});

test("scripts/alfa is valid shell", () => {
  const checked = spawnSync("sh", ["-n", join(root, "scripts/alfa")], { encoding: "utf8" });
  assert.equal(checked.status, 0, checked.stderr);
});

test("curl wget-shim downloads HTTPS like opkg needs", () => {
  const dir = mkdtempSync(join(tmpdir(), "alfa-wget-"));
  const wget = join(dir, "wget");
  const curlBin = process.env.CURL || "curl";
  writeFileSync(wget, `#!/bin/sh
OUT=""
URL=""
while [ $# -gt 0 ]; do
  case "$1" in
    -O|--output-document) OUT="$2"; shift 2 ;;
    -O*) OUT="\${1#-O}"; shift ;;
    -q|--quiet) shift ;;
    -T|--timeout) shift 2 ;;
    -*) shift ;;
    *) URL="$1"; shift ;;
  esac
done
[ -n "$URL" ] || exit 1
exec ${JSON.stringify(curlBin)} -fsSL --connect-timeout 30 -o "$OUT" "$URL"
`);
  chmodSync(wget, 0o755);
  const out = join(dir, "Packages.gz");
  const run = spawnSync(wget, ["-q", "-O", out, "https://bin.entware.net/aarch64-k3.10/Packages.gz"], {
    encoding: "utf8",
  });
  assert.equal(run.status, 0, run.stderr || run.stdout);
  assert.ok(existsSync(out));
  assert.ok(readFileSync(out).length > 1000);
});

test("Entware aarch64 index lists package node with ipk filename", () => {
  const gz = execFileSync("curl", ["-fsSL", "https://bin.entware.net/aarch64-k3.10/Packages.gz"], {
    maxBuffer: 20 * 1024 * 1024,
  });
  const text = gunzipSync(gz).toString("utf8");
  assert.match(text, /^Package: node$/m);
  assert.match(text, /Filename: node_v[\d.]+-\d+_aarch64-3\.10\.ipk/);
  const block = text.split(/\n\n/).find((chunk) => chunk.startsWith("Package: node\n"));
  assert.ok(block);
  assert.match(block, /Depends: .*libopenssl/);
});

test("install.sh has HTTPS opkg bypass and prefers package node", () => {
  const text = readFileSync(installSh, "utf8");
  assert.match(text, /install_wget_shim/);
  assert.match(text, /opkg_install_via_curl/);
  assert.match(text, /preferred_feed|http_feed/);
  assert.match(text, /opkg install node/);
  assert.match(text, /BusyBox wget/);
  assert.match(text, /resolve_node/);
  assert.match(text, /\/opt\/bin\/node/);
});

test("service script starts absolute /opt/bin/node not bare node", () => {
  const text = readFileSync(join(root, "scripts/alfa"), "utf8");
  assert.match(text, /resolve_node/);
  assert.match(text, /nohup "\$NODE_BIN" server\.mjs/);
  assert.doesNotMatch(text, /nohup node server\.mjs/);
});

test("reset-password stops panel before rewriting hash then health-checks", () => {
  const text = readFileSync(join(root, "scripts/alfa"), "utf8");
  assert.match(text, /wait_stopped/);
  assert.match(text, /wait_healthy/);
  const fn = text.slice(text.indexOf("reset_password()"), text.indexOf('case "$1"'));
  const stopAt = fn.indexOf("wait_stopped");
  const writeAt = fn.indexOf('"$NODE_BIN" "$ADDON_DIR/scripts/reset-password.mjs"');
  const startAt = fn.search(/\n\s*start /);
  assert.ok(stopAt >= 0 && writeAt >= 0 && startAt >= 0);
  assert.ok(stopAt < writeAt, "stop before writing hash");
  assert.ok(writeAt < startAt, "write hash before start");
});

test("Entware node.ipk downloads over HTTP (router-safe path)", () => {
  const gz = execFileSync("curl", ["-fsSL", "http://bin.entware.net/aarch64-k3.10/Packages.gz"], {
    maxBuffer: 20 * 1024 * 1024,
  });
  const text = gunzipSync(gz).toString("utf8");
  const file = /Filename: (node_v[\d.]+-\d+_aarch64-3\.10\.ipk)/.exec(text)?.[1];
  assert.ok(file);
  const dir = mkdtempSync(join(tmpdir(), "alfa-ipk-"));
  const out = join(dir, file);
  const run = spawnSync("curl", ["-fsSL", "-o", out, `http://bin.entware.net/aarch64-k3.10/${file}`], {
    encoding: "utf8",
  });
  assert.equal(run.status, 0, run.stderr);
  assert.ok(readFileSync(out).length > 1_000_000);
});
