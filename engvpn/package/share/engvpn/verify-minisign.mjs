#!/usr/bin/env node
/**
 * Verify a minisign signature for an EngVPN package.
 * Usage: node verify-minisign.mjs <file> <file.minisig> [pubkey-file]
 */
import { readFileSync, existsSync } from "node:fs";
import { createHash, createPublicKey, verify as cryptoVerify } from "node:crypto";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const file = process.argv[2];
const sigFile = process.argv[3];
const keyArg = process.argv[4];
const HERE = dirname(fileURLToPath(import.meta.url));
const bundledPub = join(HERE, "engvpn.minisign.pub");
const pubFile = keyArg || (existsSync(bundledPub) ? bundledPub : join(HERE, "../../../../keys/engvpn.minisign.pub"));

if (!file || !sigFile) {
  console.error("Usage: verify-minisign.mjs <file> <sig> [pubkey]");
  process.exit(2);
}
if (!existsSync(file) || !existsSync(sigFile) || !existsSync(pubFile)) {
  console.error("verify-minisign: missing file/sig/pubkey");
  process.exit(1);
}

try {
  execFileSync("minisign", ["-Vm", file, "-x", sigFile, "-p", pubFile], {
    stdio: ["ignore", "pipe", "pipe"],
  });
  console.log("ok minisign-cli");
  process.exit(0);
} catch {
  /* Node fallback */
}

/** SPKI prefix for raw 32-byte Ed25519 public keys */
const ED25519_SPKI_PREFIX = Buffer.from("302a300506032b6570032100", "hex");

function decodeKey(pubPath) {
  const lines = readFileSync(pubPath, "utf8").trim().split(/\r?\n/);
  const b64 = lines.find((l) => !l.startsWith("untrusted comment") && l.trim());
  if (!b64) throw new Error("bad pubkey");
  const raw = Buffer.from(b64.trim(), "base64");
  if (raw.length < 42 || raw[0] !== 0x45 || raw[1] !== 0x64) throw new Error("not an Ed minisign key");
  return { keyId: raw.subarray(2, 10), pub: raw.subarray(10, 42) };
}

function decodeSig(sigPath) {
  const lines = readFileSync(sigPath, "utf8").trim().split(/\r?\n/);
  const dataLines = lines.filter((l) => !l.startsWith("untrusted") && !l.startsWith("trusted") && l.trim());
  if (!dataLines.length) throw new Error("bad signature file");
  const raw = Buffer.from(dataLines[0].trim(), "base64");
  if (raw.length < 74 || raw[0] !== 0x45 || raw[1] !== 0x64) throw new Error("not an Ed minisign sig");
  return { keyId: raw.subarray(2, 10), sig: raw.subarray(10, 74) };
}

try {
  const { keyId, pub } = decodeKey(pubFile);
  const sig = decodeSig(sigFile);
  if (!keyId.equals(sig.keyId)) {
    console.error("verify-minisign: key id mismatch");
    process.exit(1);
  }
  const keyObj = createPublicKey({
    key: Buffer.concat([ED25519_SPKI_PREFIX, pub]),
    format: "der",
    type: "spki",
  });
  const data = readFileSync(file);
  const hash = createHash("blake2b512").update(data).digest();
  // Default minisign (-H): Ed25519 over blake2b-512(file)
  let ok = cryptoVerify(null, hash, keyObj, sig.sig);
  if (!ok) ok = cryptoVerify(null, data, keyObj, sig.sig);
  if (!ok) {
    console.error("verify-minisign: signature invalid");
    process.exit(1);
  }
  console.log("ok node-ed25519");
  process.exit(0);
} catch (e) {
  console.error(`verify-minisign: ${e.message || e}`);
  process.exit(1);
}
