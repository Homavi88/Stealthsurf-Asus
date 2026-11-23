#!/usr/bin/env node
/**
 * Read a panel password from stdin and write pbkdf2-sha256 into data/state.json.
 * Password never appears on argv.
 */
import { existsSync, mkdirSync, readFileSync, writeFileSync, renameSync } from "node:fs";
import { join } from "node:path";
import { pbkdf2Sync, randomBytes } from "node:crypto";
import { createInterface } from "node:readline";

const ITER = 120000;

function parseArgs(argv) {
  let dataDir = "";
  for (let i = 2; i < argv.length; i++) {
    if (argv[i] === "--data-dir") dataDir = argv[++i] || "";
  }
  return { dataDir };
}

function hashPassword(password, salt = randomBytes(16).toString("hex")) {
  const pass = String(password);
  const hash = pbkdf2Sync(pass, salt, ITER, 32, "sha256").toString("hex");
  return { salt, hash, algo: "pbkdf2-sha256", iterations: ITER };
}

function readStdinPassword() {
  return new Promise((resolve, reject) => {
    const chunks = [];
    process.stdin.on("data", (c) => chunks.push(c));
    process.stdin.on("end", () => {
      let raw = Buffer.concat(chunks).toString("utf8");
      if (raw.endsWith("\n")) raw = raw.slice(0, -1);
      if (raw.endsWith("\r")) raw = raw.slice(0, -1);
      resolve(raw);
    });
    process.stdin.on("error", reject);
    // When stdin is a TTY (interactive), read one line.
    if (process.stdin.isTTY) {
      const rl = createInterface({ input: process.stdin, output: process.stderr, terminal: true });
      rl.question("", (answer) => {
        rl.close();
        resolve(answer);
      });
    }
  });
}

function validatePassword(password) {
  const length = [...password].length;
  if (length < 8 || length > 128) {
    throw new Error("password must be 8–128 characters");
  }
  for (const ch of password) {
    const code = ch.codePointAt(0);
    if (code < 0x20 || code === 0x7f || (code >= 0x80 && code <= 0x9f)) {
      throw new Error("password must not contain control characters");
    }
  }
}

const { dataDir } = parseArgs(process.argv);
if (!dataDir) {
  console.error("set-password.mjs: --data-dir required");
  process.exit(2);
}

mkdirSync(dataDir, { recursive: true, mode: 0o700 });
const statePath = join(dataDir, "state.json");
let state = {};
if (existsSync(statePath)) {
  try {
    state = JSON.parse(readFileSync(statePath, "utf8"));
  } catch {
    state = {};
  }
}

const password = await readStdinPassword();
try {
  validatePassword(password);
} catch (err) {
  console.error(String(err.message || err));
  process.exit(1);
}

state.password = hashPassword(password);
state.version = state.version || "0.1.0";
state.openAccess = false;

const tmp = `${statePath}.new`;
writeFileSync(tmp, `${JSON.stringify(state, null, 2)}\n`, { mode: 0o600 });
renameSync(tmp, statePath);
console.log("panel password saved");
