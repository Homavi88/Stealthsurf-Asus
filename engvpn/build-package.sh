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

for f in install.sh service.sh hook.sh netfilter.sh transparent.sh update.sh dpi.sh warp.sh backup.sh discover-devices.sh smartdns.sh set-password.mjs verify-minisign.mjs; do
	cp -a "$ROOT/package/share/engvpn/$f" "$STAGE/share/engvpn/$f"
	chmod 0755 "$STAGE/share/engvpn/$f" 2>/dev/null || chmod 0644 "$STAGE/share/engvpn/$f"
done
cp -a "$ROOT/VERSION" "$STAGE/share/engvpn/VERSION"
# Minisign public key (verify on install/update)
if [ -f "$ROOT/keys/engvpn.minisign.pub" ]; then
	cp -a "$ROOT/keys/engvpn.minisign.pub" "$STAGE/share/engvpn/engvpn.minisign.pub"
elif [ -f "$ROOT/package/share/engvpn/engvpn.minisign.pub" ]; then
	cp -a "$ROOT/package/share/engvpn/engvpn.minisign.pub" "$STAGE/share/engvpn/engvpn.minisign.pub"
fi
# Default transparent config template (mode=off; prefer TPROXY when modules allow)
cat >"$STAGE/share/engvpn/transparent.conf.example" <<'EOF'
mode=off
method=auto
port=12345
mark=0x39000
table=79
killswitch=0
lan_if=br0
lan_cidr=
EOF
cat >"$STAGE/share/engvpn/dpi.conf.example" <<'EOF'
enabled=0
queue=390
youtube=1
discord=1
mode=nfqws
EOF
cat >"$STAGE/share/engvpn/gre.conf.example" <<'EOF'
gre_enabled=0
gre_remote=
gre_local=
gre_dev=engvpn-gre
EOF
cat >"$STAGE/share/engvpn/smartdns.conf.example" <<'EOF'
enabled=0
EOF
cat >"$STAGE/share/engvpn/smartdns-bypass.txt.example" <<'EOF'
# domain, IP or CIDR — traffic to these goes direct (no VPN)
# example.com
# 1.2.3.4
# 10.0.0.0/8
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

# EngVPN overlays (catalog + daemon helpers + branded panel UI)
cp -a "$ROOT/overlays/catalog.mjs" "$RUNTIME/lib/catalog.mjs"
cp -a "$ROOT/overlays/runtime-engvpn.mjs" "$RUNTIME/lib/runtime-engvpn.mjs"
if [ -d "$ROOT/overlays/public" ]; then
	mkdir -p "$RUNTIME/public"
	cp -a "$ROOT/overlays/public/." "$RUNTIME/public/"
fi

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
text = text.replace('theme: "dark"', 'theme: "light"')
text = text.replace('accent: "stealth"', 'accent: "engvpn"')
text = text.replace('oled: true', 'oled: false')
text = text.replace(
    'subscriptionName: "Основная подписка"',
    'subscriptionName: "Локальные подписки",\n    apiKeySet: false,\n    apiKeyMasked: "",\n    balance: null,\n    cloud: false',
)
text = text.replace(
    'note: "Альфа собрана локально и не ставится поверх прошивки сама."',
    'note: "EngVPN обновляется из своего feed (SHA-256 + Minisign) через engvpnd update."',
)
text = text.replace(
    'firmware: `${platform()} / стенд альфы`',
    'firmware: `${platform()} / EngVPN`',
)
text = text.replace(
    'referencePanel: "http://192.168.50.1:8800"',
    'referencePanel: "http://192.168.50.1:8790"',
)
# Prefer live LAN discovery over demo devices (empty until scan fills)
if "demoDevices()" in text and "devices: []" not in text:
    text = text.replace("devices: demoDevices(),", "devices: [],  // filled by EngVPN LAN discovery (ARP/dnsmasq)")
st.write_text(text)
print("patched state.mjs EngVPN defaults")
# runtime.mjs: EngVPN invoke + brand strings + StealthSurf-shaped get_* aliases
rtm = rt / "lib/runtime.mjs"
text = rtm.read_text()
text = text.replace("stealthsurf-alfa", "engvpn")
text = text.replace("Сброс: /jffs/scripts/alfa reset-password", "Сброс: engvpnd set-password")
text = text.replace('filename: "stealthsurf-alfa.json"', 'filename: "engvpn-settings.json"')
text = text.replace('await mqttPublish(mqtt, "stealthsurf/vpn", payload);', 'await mqttPublish(mqtt, "engvpn/vpn", payload);')
text = text.replace("Альфа ", "EngVPN ")
text = text.replace("слушает панель на порту 8788", "слушает панель на порту 8790")
if "from \"./runtime-engvpn.mjs\"" not in text:
    text = text.replace(
        'import { ENGINES, engineSupports, pickEngine } from "./catalog.mjs";',
        'import { ENGINES, engineSupports, pickEngine } from "./catalog.mjs";\n'
        'import { engvpnTransparent, engvpnUpdateCheck, engvpnReconnect, engvpnWatchdog, engvpnDpi, engvpnWarp, engvpnSaveAccount, engvpnSyncAccount, engvpnSmartDns, engvpnBackup, mergeDiscoveredDevices, readSmartDns, writeTransparentConf, modeFromRouter, engvpnParityInvoke, readAccountFile } from "./runtime-engvpn.mjs";',
    )
elif "readSmartDns" not in text and "engvpnSmartDns" in text:
    text = text.replace(
        "engvpnSmartDns, engvpnBackup, mergeDiscoveredDevices, writeTransparentConf",
        "engvpnSmartDns, engvpnBackup, mergeDiscoveredDevices, readSmartDns, writeTransparentConf",
    )
elif "engvpnSmartDns" not in text:
    text = text.replace(
        "writeTransparentConf, modeFromRouter, engvpnParityInvoke, readAccountFile } from \"./runtime-engvpn.mjs\";",
        "engvpnSmartDns, engvpnBackup, mergeDiscoveredDevices, readSmartDns, writeTransparentConf, modeFromRouter, engvpnParityInvoke, readAccountFile } from \"./runtime-engvpn.mjs\";",
    )
elif "engvpnSaveAccount" not in text:
    text = text.replace(
        "writeTransparentConf, modeFromRouter, engvpnParityInvoke } from \"./runtime-engvpn.mjs\";",
        "engvpnDpi, engvpnWarp, engvpnSaveAccount, engvpnSyncAccount, engvpnSmartDns, engvpnBackup, mergeDiscoveredDevices, readSmartDns, writeTransparentConf, modeFromRouter, engvpnParityInvoke, readAccountFile } from \"./runtime-engvpn.mjs\";",
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
      case "engvpnDpi":
      case "dpi":
        return engvpnDpi(body.action || body.command || "status", body);
      case "engvpnWarp":
        return engvpnWarp(body.action || body.command || "status", body);
      case "saveAccount":
      case "save_account":
        return engvpnSaveAccount(body, state, { parseShareLink, parseSubscriptionBody, directNode, saveState, snapshot, refreshSubscription });
      case "syncAccount":
      case "sync_account":
        return engvpnSyncAccount(state, { parseShareLink, parseSubscriptionBody, directNode, saveState, snapshot, refreshSubscription });
      case "clearAccount":
      case "clear_account":
        return engvpnSaveAccount({ clearKey: true }, state, { parseShareLink, parseSubscriptionBody, directNode, saveState, snapshot, refreshSubscription });
      case "smartdns":
      case "smartDns":
      case "engvpnSmartDns":
        return engvpnSmartDns(body.action || body.command || "apply", body);
      case "engvpnBackup":
      case "backup":
        return engvpnBackup(body.action || body.command || "create", body.prefix);
      case "scanDevices":
      case "refreshDevices":
        mergeDiscoveredDevices(state);
        saveState(state);
        return snapshot();
      case "autoSetup":'''
if "case \"transparent\":" not in text:
    if needle not in text:
        raise SystemExit("autoSetup case not found for inject")
    text = text.replace(needle, insert, 1)
elif "case \"saveAccount\":" not in text:
    text = text.replace(
        '      case "engvpnWatchdog":\n        return engvpnWatchdog();\n      case "autoSetup":',
        '      case "engvpnWatchdog":\n        return engvpnWatchdog();\n'
        '      case "engvpnDpi":\n      case "dpi":\n        return engvpnDpi(body.action || body.command || "status", body);\n'
        '      case "engvpnWarp":\n        return engvpnWarp(body.action || body.command || "status", body);\n'
        '      case "saveAccount":\n      case "save_account":\n'
        '        return engvpnSaveAccount(body, state, { parseShareLink, parseSubscriptionBody, directNode, saveState, snapshot, refreshSubscription });\n'
        '      case "syncAccount":\n      case "sync_account":\n'
        '        return engvpnSyncAccount(state, { parseShareLink, parseSubscriptionBody, directNode, saveState, snapshot, refreshSubscription });\n'
        '      case "clearAccount":\n      case "clear_account":\n'
        '        return engvpnSaveAccount({ clearKey: true }, state, { parseShareLink, parseSubscriptionBody, directNode, saveState, snapshot, refreshSubscription });\n'
        '      case "smartdns":\n      case "smartDns":\n      case "engvpnSmartDns":\n'
        '        return engvpnSmartDns(body.action || body.command || "apply", body);\n'
        '      case "engvpnBackup":\n      case "backup":\n'
        '        return engvpnBackup(body.action || body.command || "create", body.prefix);\n'
        '      case "scanDevices":\n      case "refreshDevices":\n'
        '        mergeDiscoveredDevices(state);\n'
        '        saveState(state);\n'
        '        return snapshot();\n'
        '      case "autoSetup":',
        1,
    )
elif "case \"smartdns\":" not in text:
    text = text.replace(
        '      case "clearAccount":\n      case "clear_account":\n'
        '        return engvpnSaveAccount({ clearKey: true }, state, { parseShareLink, parseSubscriptionBody, directNode, saveState, snapshot, refreshSubscription });\n'
        '      case "autoSetup":',
        '      case "clearAccount":\n      case "clear_account":\n'
        '        return engvpnSaveAccount({ clearKey: true }, state, { parseShareLink, parseSubscriptionBody, directNode, saveState, snapshot, refreshSubscription });\n'
        '      case "smartdns":\n      case "smartDns":\n      case "engvpnSmartDns":\n'
        '        return engvpnSmartDns(body.action || body.command || "apply", body);\n'
        '      case "engvpnBackup":\n      case "backup":\n'
        '        return engvpnBackup(body.action || body.command || "create", body.prefix);\n'
        '      case "scanDevices":\n      case "refreshDevices":\n'
        '        mergeDiscoveredDevices(state);\n'
        '        saveState(state);\n'
        '        return snapshot();\n'
        '      case "autoSetup":',
        1,
    )

# Define transparent sync helper BEFORE invoke / parity wrappers reference it
if "async function engvpnSyncTransparent()" not in text:
    if "async function invoke(command, body = {}) {" not in text:
        raise SystemExit("invoke() not found for engvpnSyncTransparent")
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
        1,
    )

# Hook router.mode patches → transparent.conf
old_patch = '      case "patch":\n        return patch(body.path, body.value);'
new_patch = (
    '      case "patch": {\n'
    "        const result = patch(body.path, body.value);\n"
    "        if (body?.path === \"router.mode\" || body?.path === \"router.transparentMethod\" || body?.path === \"router.blockWithoutVpn\") {\n"
    "          if (body?.path === \"router.transparentMethod\") writeTransparentConf({ method: body.value || \"auto\" });\n"
    "          if (body?.path === \"router.blockWithoutVpn\") writeTransparentConf({ killswitch: body.value ? \"1\" : \"0\" });\n"
    "          await engvpnSyncTransparent();\n"
    "        }\n"
    "        if (body?.path === \"network.youtubeZapret\" || body?.path === \"network.discordZapret\") {\n"
    "          try {\n"
    "            const want = !!(state.network?.youtubeZapret || state.network?.discordZapret);\n"
    "            await engvpnDpi(want ? \"apply\" : \"stop\", { enabled: want, youtube: !!state.network?.youtubeZapret, discord: !!state.network?.discordZapret });\n"
    "          } catch (e) { ctx.hooks.log(\"warn\", `dpi toggle: ${e.message || e}`); }\n"
    "        }\n"
    "        return result;\n"
    "      }"
)
if old_patch in text and 'if (body?.path === "router.mode")' not in text:
    text = text.replace(old_patch, new_patch, 1)
elif 'router.transparentMethod' not in text and 'if (body?.path === "router.mode")' in text:
    text = text.replace(
        '        if (body?.path === "router.mode") {\n'
        '          await engvpnSyncTransparent();\n'
        '        }',
        '        if (body?.path === "router.mode" || body?.path === "router.transparentMethod" || body?.path === "router.blockWithoutVpn") {\n'
        '          if (body?.path === "router.transparentMethod") writeTransparentConf({ method: body.value || "auto" });\n'
        '          if (body?.path === "router.blockWithoutVpn") writeTransparentConf({ killswitch: body.value ? "1" : "0" });\n'
        '          await engvpnSyncTransparent();\n'
        '        }\n'
        '        if (body?.path === "network.youtubeZapret" || body?.path === "network.discordZapret") {\n'
        '          try {\n'
        '            const want = !!(state.network?.youtubeZapret || state.network?.discordZapret);\n'
        '            await engvpnDpi(want ? "apply" : "stop", { enabled: want, youtube: !!state.network?.youtubeZapret, discord: !!state.network?.discordZapret });\n'
        '          } catch (e) { ctx.hooks.log("warn", `dpi toggle: ${e.message || e}`); }\n'
        '        }',
        1,
    )

# Enrich snapshot with smartdns + one-shot LAN discover when only demos/empty
import re as _re
if "__snap.smartdns" not in text:
    m = _re.search(r"function snapshot\(\)\s*\{.*?^\s*(return publicState\([^;]+;)", text, _re.S | _re.M)
    if m:
        ret = m.group(1)
        replacement = (
            "const __snap = " + ret[len("return "):].rstrip(";") + ";\n"
            "    try { __snap.smartdns = readSmartDns(); } catch { __snap.smartdns = { enabled: false, entries: [] }; }\n"
            "    try {\n"
            "      const onlyDemo = !(state.devices || []).length || (state.devices || []).every((d) => d.demo);\n"
            "      if (onlyDemo) mergeDiscoveredDevices(state);\n"
            "    } catch { /* ignore */ }\n"
            "    return __snap;"
        )
        text = text[: m.start(1)] + replacement + text[m.end(1) :]
        print("patched snapshot() with smartdns + discover")

if "engvpnSmartDns" in text and "alias === \"engvpnSmartDns\"" not in text and "engvpnParityInvoke(" in text:
    text = text.replace(
        "      if (parity && parity.alias === \"engvpnSyncAccount\") return engvpnSyncAccount(state, { parseShareLink, parseSubscriptionBody, directNode, saveState, snapshot, refreshSubscription });\n",
        "      if (parity && parity.alias === \"engvpnSyncAccount\") return engvpnSyncAccount(state, { parseShareLink, parseSubscriptionBody, directNode, saveState, snapshot, refreshSubscription });\n"
        "      if (parity && parity.alias === \"engvpnSmartDns\") return engvpnSmartDns(parity.action || \"apply\", parity);\n"
        "      if (parity && parity.alias === \"engvpnBackup\") return engvpnBackup(parity.action || \"create\", parity.prefix);\n",
        1,
    )

# StealthSurf-compatible get_* / update_router_settings before switch body
if "engvpnParityInvoke(" not in text:
    text = text.replace(
        "  async function invoke(command, body = {}) {\n    switch (command) {",
        "  async function invoke(command, body = {}) {\n"
        "    const parity = engvpnParityInvoke(command, body, state, snapshot);\n"
        "    if (parity !== undefined) {\n"
        "      if (parity && parity.alias === \"selectNode\") return selectNode(parity.id);\n"
        "      if (parity && parity.alias === \"setPassword\") return setPassword({ oldPassword: parity.oldPassword || parity.current || \"\", password: parity.password || parity.newPassword || \"\" });\n"
        "      if (parity && parity.alias === \"engvpnSaveAccount\") return engvpnSaveAccount(parity, state, { parseShareLink, parseSubscriptionBody, directNode, saveState, snapshot, refreshSubscription });\n"
        "      if (parity && parity.alias === \"engvpnSyncAccount\") return engvpnSyncAccount(state, { parseShareLink, parseSubscriptionBody, directNode, saveState, snapshot, refreshSubscription });\n"
        "      if (parity && parity.alias === \"engvpnSmartDns\") return engvpnSmartDns(parity.action || \"apply\", parity);\n"
        "      if (parity && parity.alias === \"engvpnBackup\") return engvpnBackup(parity.action || \"create\", parity.prefix);\n"
        "      if (command === \"update_router_settings\") {\n"
        "        saveState(state);\n"
        "        try { await engvpnSyncTransparent(); } catch { /* ignore */ }\n"
        "        return snapshot();\n"
        "      }\n"
        "      if (parity && typeof parity.then === \"function\") return parity;\n"
        "      return parity;\n"
        "    }\n"
        "    switch (command) {",
        1,
    )
# Override closed WARP stubs with open engvpnWarp
if "engvpnWarp(\"create\")" not in text:
    text = text.replace(
        '''      case "warpCreate":
        state.connection.warpProfile = {
          id: randomUUID().slice(0, 8),
          createdAt: Date.now(),
          method: state.connection.warpMethod,
          status: "local",
          note: "Локальная заготовка. Для настоящего WARP импортируйте профиль wgcf.",
        };
        saveState(state);
        return snapshot();
      case "warpImport":
        state.connection.warpProfile = { ...parseWireGuardIni(body.text || ""), status: "imported", createdAt: Date.now() };
        saveState(state);
        return snapshot();''',
        '''      case "warpCreate": {
        const wr = await engvpnWarp("create", body);
        const iniPath = (await import("node:path")).join(DATA, "warp.profile.ini");
        let ini = "";
        try { ini = (await import("node:fs")).readFileSync(iniPath, "utf8"); } catch { /* ignore */ }
        state.connection.warpProfile = { ...parseWireGuardIni(ini || body.text || ""), status: "warp-open", createdAt: Date.now(), note: wr.output || "Cloudflare WARP (open)" };
        state.connection.warpMode = state.connection.warpMode === "off" ? "proxy" : state.connection.warpMode;
        saveState(state);
        return snapshot();
      }
      case "warpImport": {
        await engvpnWarp("import", body);
        state.connection.warpProfile = { ...parseWireGuardIni(body.text || ""), status: "imported", createdAt: Date.now() };
        saveState(state);
        return snapshot();
      }''',
        1,
    )
# Hook zapret recheck → also apply open DPI when youtube/discord zapret enabled
if "engvpnDpi(\"apply\"" not in text:
    text = text.replace(
        "    state.network.zapret.lastCheck = Date.now();\n"
        "    state.network.zapret.checking = false;\n"
        "    ctx.hooks.log(\"info\", all ? \"Проверка способов завершена, сервисы возвращены из запасного VPN\" : \"Рабочие прямые пути подтверждены\");\n"
        "    if (state.vpn.connected) await connect();\n"
        "    else saveState(state);\n"
        "    return snapshot();\n"
        "  }",
        "    state.network.zapret.lastCheck = Date.now();\n"
        "    state.network.zapret.checking = false;\n"
        "    try {\n"
        "      const want = !!(state.network.youtubeZapret || state.network.discordZapret);\n"
        "      await engvpnDpi(want ? \"apply\" : \"stop\", { enabled: want, youtube: !!state.network.youtubeZapret, discord: !!state.network.discordZapret });\n"
        "      ctx.hooks.log(\"info\", want ? \"DPI nfqws: apply\" : \"DPI nfqws: stop\");\n"
        "    } catch (e) {\n"
        "      ctx.hooks.log(\"warn\", `dpi: ${e.message || e}`);\n"
        "    }\n"
        "    ctx.hooks.log(\"info\", all ? \"Проверка способов завершена, сервисы возвращены из запасного VPN\" : \"Рабочие прямые пути подтверждены\");\n"
        "    if (state.vpn.connected) await connect();\n"
        "    else saveState(state);\n"
        "    return snapshot();\n"
        "  }",
        1,
    )
rtm.write_text(text)
print("patched runtime.mjs EngVPN commands")
# dokodemo inbound injection into xray plan when transparent mode != off
eng = rt / "lib/engines.mjs"
et = eng.read_text()
et = et.replace("stealthsurf-alfa", "engvpn")
# Ferrum open slot: download Xray-core as ferrum binary
if 'if (id === "ferrum")' in et and "open-xray-reality" not in et:
    et = et.replace(
        '''export async function downloadCore(id, onProgress) {
  if (id === "ferrum") {
    throw new Error("Ferrum — ядро StealthSurf. Его нет в открытых релизах, положите бинарник в data/cores/ferrum");
  }
  const spec = ENGINES[id];
  if (!spec?.repo) throw new Error("Неизвестное ядро");
  onProgress?.(`смотрю релиз ${spec.repo}`);
  const release = await githubLatest(spec.repo);
  const asset = pickCoreAsset(id, release);''',
        '''export async function downloadCore(id, onProgress) {
  const spec = ENGINES[id];
  if (!spec?.repo) throw new Error("Неизвестное ядро");
  // Ferrum slot: open Xray-core (Reality-capable), saved as data/cores/ferrum
  const assetId = id === "ferrum" ? "xray" : id;
  onProgress?.(id === "ferrum" ? `Ferrum-слот: скачиваю открытый Xray (${spec.repo})` : `смотрю релиз ${spec.repo}`);
  const release = await githubLatest(spec.repo);
  const asset = pickCoreAsset(assetId, release);''',
    )
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

# Minisign: sign archives when secret key is available
MINISIGN_KEY=${ENGVPN_MINISIGN_KEY:-$ROOT/keys/engvpn.minisign.key}
sign_one() {
	arch=$1
	pkg="$OUT/engvpn_${VERSION}_${arch}.tar.gz"
	if [ -f "$MINISIGN_KEY" ] && command -v minisign >/dev/null 2>&1; then
		minisign -Sm "$pkg" -s "$MINISIGN_KEY" </dev/null || true
		[ -f "${pkg}.minisig" ] && echo "signed $arch" || echo "sign skipped $arch"
	else
		echo "minisign key missing — skip signing $arch (SHA-256 only)"
	fi
}
sign_one merlin-aarch64
sign_one merlin-armv7
sign_one merlin-x86_64

minisig_field() {
	arch=$1
	sig="$OUT/engvpn_${VERSION}_${arch}.tar.gz.minisig"
	if [ -f "$sig" ]; then
		printf '"minisig": "file://%s",' "$sig"
	else
		printf '"minisig": "",'
	fi
}
minisig_release() {
	arch=$1
	sig="$OUT/engvpn_${VERSION}_${arch}.tar.gz.minisig"
	if [ -f "$sig" ]; then
		printf '"minisig": "https://github.com/Homavi88/Stealthsurf-Asus/releases/download/engvpn-%s/engvpn_%s_%s.tar.gz.minisig",' "$VERSION" "$VERSION" "$arch"
	else
		printf '"minisig": "",'
	fi
}

# Local file:// feed for smoke; also write relative GitHub-style URLs for docs
FEED=$ROOT/feed/latest.json
cat >"$FEED" <<EOF
{
  "version": "$VERSION",
  "notes": "EngVPN 0.5 — backup/restore, LAN ARP discovery, SmartDNS bypass, UI polish.",
  "packages": {
    "merlin-aarch64": {
      "url": "file://$OUT/engvpn_${VERSION}_merlin-aarch64.tar.gz",
      $(minisig_field merlin-aarch64)
      "sha256": "$sha64",
      "size": $size64
    },
    "merlin-armv7": {
      "url": "file://$OUT/engvpn_${VERSION}_merlin-armv7.tar.gz",
      $(minisig_field merlin-armv7)
      "sha256": "$sha7",
      "size": $size7
    },
    "merlin-x86_64": {
      "url": "file://$OUT/engvpn_${VERSION}_merlin-x86_64.tar.gz",
      $(minisig_field merlin-x86_64)
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
  "notes": "EngVPN 0.5 — backup/restore, LAN ARP discovery, SmartDNS bypass, UI polish.",
  "packages": {
    "merlin-aarch64": {
      "url": "https://github.com/Homavi88/Stealthsurf-Asus/releases/download/engvpn-$VERSION/engvpn_${VERSION}_merlin-aarch64.tar.gz",
      $(minisig_release merlin-aarch64)
      "sha256": "$sha64",
      "size": $size64
    },
    "merlin-armv7": {
      "url": "https://github.com/Homavi88/Stealthsurf-Asus/releases/download/engvpn-$VERSION/engvpn_${VERSION}_merlin-armv7.tar.gz",
      $(minisig_release merlin-armv7)
      "sha256": "$sha7",
      "size": $size7
    },
    "merlin-x86_64": {
      "url": "https://github.com/Homavi88/Stealthsurf-Asus/releases/download/engvpn-$VERSION/engvpn_${VERSION}_merlin-x86_64.tar.gz",
      $(minisig_release merlin-x86_64)
      "sha256": "$shax",
      "size": $sizex
    }
  }
}
EOF

echo "Wrote $FEED"
ls -la "$OUT"
echo "Done."
