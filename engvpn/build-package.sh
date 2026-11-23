#!/bin/sh
# Build EngVPN Merlin packages (arch keys for feed parity; payload is arch-independent JS+shell).
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$ROOT/.." && pwd)
VERSION=$(cat "$ROOT/VERSION")
OUT=$ROOT/dist
STAGE=$OUT/stage
ALFA=$REPO/alfa-addon

rm -rf "$OUT"
mkdir -p "$STAGE/sbin" "$STAGE/share/engvpn" "$OUT"

# Daemon + share scripts
cp -a "$ROOT/package/sbin/engvpnd" "$STAGE/sbin/engvpnd"
chmod 0755 "$STAGE/sbin/engvpnd"

for f in install.sh service.sh hook.sh netfilter.sh transparent.sh update.sh set-password.mjs; do
	cp -a "$ROOT/package/share/engvpn/$f" "$STAGE/share/engvpn/$f"
	chmod 0755 "$STAGE/share/engvpn/$f" 2>/dev/null || chmod 0644 "$STAGE/share/engvpn/$f"
done
cp -a "$ROOT/VERSION" "$STAGE/share/engvpn/VERSION"
# Default transparent config template (mode=off)
cat >"$STAGE/share/engvpn/transparent.conf.example" <<'EOF'
mode=off
method=redirect
port=12345
mark=0x39000
table=79
killswitch=0
lan_if=br0
lan_cidr=
EOF

# Vendor open panel runtime from alfa-addon (no proprietary binaries).
RUNTIME=$STAGE/share/engvpn/runtime
mkdir -p "$RUNTIME"
if [ ! -d "$ALFA" ]; then
	echo "build-package: missing $ALFA" >&2
	exit 1
fi

# Copy runtime sources (exclude data, tests, install.sh that targets /jffs/addons/alfa)
for item in lib public scripts server.mjs run.mjs package.json README.md; do
	if [ -e "$ALFA/$item" ]; then
		cp -a "$ALFA/$item" "$RUNTIME/$item"
	fi
done

# EngVPN overlays
cp -a "$ROOT/overlays/catalog.mjs" "$RUNTIME/lib/catalog.mjs"
cp -a "$ROOT/overlays/runtime-engvpn.mjs" "$RUNTIME/lib/runtime-engvpn.mjs"

# Brand run.mjs / server cookie name for EngVPN
cat >"$RUNTIME/run.mjs" <<'EOF'
/**
 * EngVPN panel entry — SIGHUP ignored before loading the server.
 */
try {
  process.on("SIGHUP", () => {});
} catch {
  /* ignore */
}

const fs = await import("node:fs");
if (process.env.ENGVPN_PID_FILE) {
  try {
    fs.writeFileSync(process.env.ENGVPN_PID_FILE, `${process.pid}\n`);
  } catch {
    /* ignore */
  }
}

process.env.ENGVPN_OPEN_PANEL = process.env.ENGVPN_OPEN_PANEL || "0";

const { start } = await import("./server.mjs");
const { PANEL_PORT } = await import("./lib/catalog.mjs");

start().then(() => {
  console.log(`EngVPN panel http://0.0.0.0:${PANEL_PORT} openAccess=${process.env.ENGVPN_OPEN_PANEL === "1"}`);
}).catch((err) => {
  console.error(err);
  process.exit(1);
});
EOF

# Patch server/runtime branding + EngVPN invoke commands (transparent / update)
RUNTIME="$RUNTIME" python3 - <<'PY'
from pathlib import Path
import os
rt = Path(os.environ["RUNTIME"])
p = rt / "server.mjs"
text = p.read_text()
text = text.replace("alfa_session", "engvpn_session")
text = text.replace("StealthSurf alfa", "EngVPN")
p.write_text(text)
print("patched server.mjs cookies/brand")
st = rt / "lib/state.mjs"
text = st.read_text()
text = text.replace('export const DEFAULT_PANEL_PASSWORD = "alfa";', 'export const DEFAULT_PANEL_PASSWORD = "changeme";')
st.write_text(text)
idx = rt / "public/index.html"
if idx.exists():
    t = idx.read_text()
    t = t.replace("StealthSurf", "EngVPN").replace("Alfa", "EngVPN").replace("alfa", "engvpn")
    idx.write_text(t)
# runtime.mjs: EngVPN invoke + brand strings
rtm = rt / "lib/runtime.mjs"
text = rtm.read_text()
text = text.replace("stealthsurf-alfa", "engvpn")
text = text.replace("Сброс: /jffs/scripts/alfa reset-password", "Сброс: engvpnd set-password")
text = text.replace('filename: "stealthsurf-alfa.json"', 'filename: "engvpn-settings.json"')
text = text.replace('await mqttPublish(mqtt, "stealthsurf/vpn", payload);', 'await mqttPublish(mqtt, "engvpn/vpn", payload);')
if "from \"./runtime-engvpn.mjs\"" not in text:
    text = text.replace(
        'import { ENGINES, engineSupports, pickEngine } from "./catalog.mjs";',
        'import { ENGINES, engineSupports, pickEngine } from "./catalog.mjs";\n'
        'import { engvpnTransparent, engvpnUpdateCheck, engvpnReconnect, engvpnWatchdog, writeTransparentConf, modeFromRouter } from "./runtime-engvpn.mjs";',
    )
needle = '      case "autoSetup":'
insert = '''      case "transparent":
        return engvpnTransparent(body.action || body.command || "status", body);
      case "transparentApply":
        return engvpnTransparent("apply", body);
      case "engvpnUpdateCheck":
      case "checkEngvpnUpdates":
        return engvpnUpdateCheck();
      case "engvpnReconnect":
        return engvpnReconnect();
      case "engvpnWatchdog":
        return engvpnWatchdog();
      case "autoSetup":'''
if "case \"transparent\":" not in text:
    if needle not in text:
        raise SystemExit("autoSetup case not found for inject")
    text = text.replace(needle, insert, 1)
# When router.mode patched, sync transparent.conf (best-effort after patch)
if "modeFromRouter(state.router.mode)" not in text:
    text = text.replace(
        "function patch(body) {",
        "function patch(body) {\n"
        "    const beforeMode = state.router?.mode;\n",
    )
    # After saveState in patch — find a simple hook: after patch returns snapshot
    # Safer: wrap end of patch via marker
    if "async function invoke(command, body = {})" in text and "engvpnSyncTransparent" not in text:
        text = text.replace(
            "async function invoke(command, body = {}) {",
            "async function engvpnSyncTransparent() {\n"
            "    try {\n"
            "      if (!state.router) return;\n"
            "      const mode = modeFromRouter(state.router.mode);\n"
            "      writeTransparentConf({ mode });\n"
            "      if (mode !== \"off\") await engvpnTransparent(\"apply\", { mode });\n"
            "      else await engvpnTransparent(\"stop\", {});\n"
            "    } catch (e) {\n"
            "      ctx.hooks.log(\"warn\", `transparent sync: ${e.message || e}`);\n"
            "    }\n"
            "  }\n\n"
            "  async function invoke(command, body = {}) {",
        )
        text = text.replace(
            '      case "patch":\n        return patch(body);',
            '      case "patch": {\n'
            "        const result = patch(body);\n"
            "        if (body?.path === \"router.mode\" || (body?.router && body.router.mode != null)) {\n"
            "          await engvpnSyncTransparent();\n"
            "        }\n"
            "        return result;\n"
            "      }",
        )
rtm.write_text(text)
print("patched runtime.mjs EngVPN commands")
# dokodemo inbound injection into xray plan when transparent mode != off
eng = rt / "lib/engines.mjs"
et = eng.read_text()
et = et.replace("stealthsurf-alfa", "engvpn")
if "engvpn-transparent" not in et:
    marker = "  if (!tunnelOnly) {\n    inbounds.push({\n      tag: \"http-in\","
    doko = '''  // EngVPN: dokodemo for iptables REDIRECT/TPROXY when data/transparent.conf mode != off
  try {
    const fs = await import("node:fs");
    const path = await import("node:path");
    const confPath = path.join(DATA, "transparent.conf");
    // DATA may be unavailable in this scope — use GEO_DIR parent
    const dataDir = path.join(GEO_DIR, "..");
    const cpath = path.join(dataDir, "transparent.conf");
    if (fs.existsSync(cpath)) {
      const conf = Object.fromEntries(
        fs.readFileSync(cpath, "utf8").split("\\n").map((l) => l.split("=")).filter((p) => p.length === 2)
      );
      if (conf.mode && conf.mode !== "off") {
        const tpPort = Number(conf.port || 12345);
        const useTp = conf.method === "tproxy";
        inbounds.push({
          tag: "engvpn-transparent",
          listen: "0.0.0.0",
          port: tpPort,
          protocol: "dokodemo-door",
          settings: { network: "tcp,udp", followRedirect: true },
          sniffing: { enabled: true, destOverride: ["http", "tls", "quic"] },
          streamSettings: { sockopt: { tproxy: useTp ? "tproxy" : "off" } },
        });
      }
    }
  } catch { /* ignore */ }
  if (!tunnelOnly) {
    inbounds.push({
      tag: "http-in",'''
    # xrayPlan is sync function — can't use await import. Use sync fs.
    doko_sync = '''  // EngVPN: dokodemo for iptables REDIRECT/TPROXY when transparent.conf mode != off
  try {
    const confPath = join(DATA, "transparent.conf");
    if (existsSync(confPath)) {
      const conf = Object.fromEntries(
        readFileSync(confPath, "utf8").split("\\n").map((l) => l.split("=")).filter((p) => p.length === 2)
      );
      if (conf.mode && conf.mode !== "off") {
        const tpPort = Number(conf.port || 12345);
        const useTp = conf.method === "tproxy";
        inbounds.push({
          tag: "engvpn-transparent",
          listen: "0.0.0.0",
          port: tpPort,
          protocol: "dokodemo-door",
          settings: { network: "tcp,udp", followRedirect: true },
          sniffing: { enabled: true, destOverride: ["http", "tls", "quic"] },
          streamSettings: { sockopt: { tproxy: useTp ? "tproxy" : "off" } },
        });
      }
    }
  } catch { /* ignore */ }
  if (!tunnelOnly) {
    inbounds.push({
      tag: "http-in",'''
    if marker not in et:
        print("WARN: dokodemo inject marker missing")
    else:
        et = et.replace(marker, doko_sync, 1)
        # Ensure imports
        if "existsSync" not in et.split("from \"node:fs\"")[0] + et.split("from \"node:fs\"")[1][:200]:
            et = et.replace(
                'import { mkdirSync, writeFileSync, readFileSync, existsSync, chmodSync, rmSync, readdirSync, statSync, createWriteStream } from "node:fs";',
                'import { mkdirSync, writeFileSync, readFileSync, existsSync, chmodSync, rmSync, readdirSync, statSync, createWriteStream } from "node:fs";',
            )
eng.write_text(et)
print("patched engines.mjs")
PY

# Manifest of all packaged files (relative to prefix)
(
	cd "$STAGE"
	find . -type f -o -type l | sed 's|^\./||' | sort
) >"$STAGE/share/engvpn/files"

# Ensure files list includes itself (already does via find after write — rewrite once more)
(
	cd "$STAGE"
	find . -type f -o -type l | sed 's|^\./||' | sort
) >"$STAGE/share/engvpn/files"

pack_one() {
	arch=$1
	name="engvpn_${VERSION}_${arch}.tar.gz"
	tar -C "$STAGE" -czf "$OUT/$name" .
	sum=$(sha256sum "$OUT/$name" | awk '{ print $1 }')
	size=$(wc -c <"$OUT/$name" | tr -d ' ')
	echo "$arch $name $sum $size"
}

echo "Building EngVPN $VERSION packages…"
A64=$(pack_one merlin-aarch64)
A7=$(pack_one merlin-armv7)
X86=$(pack_one merlin-x86_64)

sha64=$(echo "$A64" | awk '{ print $3 }')
size64=$(echo "$A64" | awk '{ print $4 }')
sha7=$(echo "$A7" | awk '{ print $3 }')
size7=$(echo "$A7" | awk '{ print $4 }')
shax=$(echo "$X86" | awk '{ print $3 }')
sizex=$(echo "$X86" | awk '{ print $4 }')

# Local file:// feed for smoke; also write relative GitHub-style URLs for docs
FEED=$ROOT/feed/latest.json
cat >"$FEED" <<EOF
{
  "version": "$VERSION",
  "notes": "EngVPN Merlin open addon — panel :8790, Node runtime, downloadable Xray/sing-box/mihomo.",
  "packages": {
    "merlin-aarch64": {
      "url": "file://$OUT/engvpn_${VERSION}_merlin-aarch64.tar.gz",
      "sha256": "$sha64",
      "size": $size64
    },
    "merlin-armv7": {
      "url": "file://$OUT/engvpn_${VERSION}_merlin-armv7.tar.gz",
      "sha256": "$sha7",
      "size": $size7
    },
    "merlin-x86_64": {
      "url": "file://$OUT/engvpn_${VERSION}_merlin-x86_64.tar.gz",
      "sha256": "$shax",
      "size": $sizex
    }
  }
}
EOF

# Release-oriented feed (URLs for GitHub Releases — update tag when publishing)
cat >"$ROOT/feed/latest.release.json" <<EOF
{
  "version": "$VERSION",
  "notes": "EngVPN Merlin open addon — panel :8790, Node runtime, downloadable Xray/sing-box/mihomo.",
  "packages": {
    "merlin-aarch64": {
      "url": "https://github.com/Homavi88/Stealthsurf-Asus/releases/download/engvpn-$VERSION/engvpn_${VERSION}_merlin-aarch64.tar.gz",
      "sha256": "$sha64",
      "size": $size64
    },
    "merlin-armv7": {
      "url": "https://github.com/Homavi88/Stealthsurf-Asus/releases/download/engvpn-$VERSION/engvpn_${VERSION}_merlin-armv7.tar.gz",
      "sha256": "$sha7",
      "size": $size7
    },
    "merlin-x86_64": {
      "url": "https://github.com/Homavi88/Stealthsurf-Asus/releases/download/engvpn-$VERSION/engvpn_${VERSION}_merlin-x86_64.tar.gz",
      "sha256": "$shax",
      "size": $sizex
    }
  }
}
EOF

echo "Wrote $FEED"
ls -la "$OUT"
echo "Done."
