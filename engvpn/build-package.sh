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

for f in install.sh service.sh hook.sh netfilter.sh transparent.sh update.sh schedule-update.sh dpi.sh warp.sh privacy-check.sh backup.sh discover-devices.sh smartdns.sh set-password.mjs verify-minisign.mjs; do
	cp -a "$ROOT/package/share/engvpn/$f" "$STAGE/share/engvpn/$f"
	chmod 0755 "$STAGE/share/engvpn/$f" 2>/dev/null || chmod 0644 "$STAGE/share/engvpn/$f"
done
cp -a "$ROOT/VERSION" "$STAGE/share/engvpn/VERSION"
cat >"$STAGE/share/engvpn/updates.conf.example" <<'EOF'
interval=1d
auto=0
window_start=2
window_end=5
geo_weekly=1
cores_when_missing=1
last_check=
last_result=
EOF
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
dns_hijack=0
dns_port=5353
captive_open=0
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
    '''    account: {
      email: "",
      balance: 0,
      subscriptionName: "Основная подписка",
      nextCharge: "",
      consoleUrl: "",
      consoleConnected: false,
      inviteCode: "",
    },''',
    '''    account: {
      email: "",
      balance: null,
      subscriptionName: "Локальные подписки",
      subscriptionUrl: "",
      apiKeySet: false,
      apiKeyMasked: "",
      cloud: false,
      nextCharge: "",
      consoleUrl: "",
      consoleConnected: false,
      inviteCode: "",
    },''',
)
# Transparent method default for panel selector
if "transparentMethod" not in text:
    text = text.replace(
        '      mode: "except",\n      dnsViaVpn: true,',
        '      mode: "except",\n      transparentMethod: "auto",\n      dnsViaVpn: true,',
        1,
    )
text = text.replace(
    'note: "Альфа собрана локально и не ставится поверх прошивки сама."',
    'note: "EngVPN обновляется из своего feed (SHA-256 + Minisign) через engvpnd update. Расписание — Merlin cru."',
)
# Scheduled update defaults: check daily, auto-apply off
text = text.replace("    updates: {\n      auto: true,", "    updates: {\n      auto: false,")
if 'interval: "6h"' in text and "updates:" in text:
    # Only the updates.interval default (first occurrence after updates block is fine)
    text = text.replace(
        '      auto: false,\n      windowStart: 2,\n      windowEnd: 5,\n      geoWeekly: true,\n      coresWhenMissing: true,\n      interval: "6h",',
        '      auto: false,\n      windowStart: 2,\n      windowEnd: 5,\n      geoWeekly: true,\n      coresWhenMissing: true,\n      interval: "1d",',
        1,
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
        'import { engvpnTransparent, engvpnUpdateCheck, engvpnScheduleUpdate, engvpnReconnect, engvpnWatchdog, engvpnDpi, engvpnWarp, engvpnPrivacyCheck, engvpnSaveAccount, engvpnSyncAccount, engvpnSmartDns, engvpnBackup, mergeDiscoveredDevices, readSmartDns, writeTransparentConf, modeFromRouter, engvpnParityInvoke, readAccountFile, hydratePanelSnapshot, syncUpdatesSchedule, syncDevicesSelect, selectedDeviceIds, transparentDnsFlags } from "./runtime-engvpn.mjs";',
    )
elif "syncDevicesSelect" not in text and "from \"./runtime-engvpn.mjs\"" in text:
    text = text.replace(
        "hydratePanelSnapshot, syncUpdatesSchedule } from \"./runtime-engvpn.mjs\";",
        "hydratePanelSnapshot, syncUpdatesSchedule, syncDevicesSelect, selectedDeviceIds, transparentDnsFlags } from \"./runtime-engvpn.mjs\";",
    )
    if "engvpnPrivacyCheck" not in text:
        text = text.replace(
            "engvpnDpi, engvpnWarp,",
            "engvpnDpi, engvpnWarp, engvpnPrivacyCheck,",
        )
elif "engvpnPrivacyCheck" not in text and "engvpnDpi" in text:
    text = text.replace(
        "engvpnDpi, engvpnWarp,",
        "engvpnDpi, engvpnWarp, engvpnPrivacyCheck,",
    )
elif "syncUpdatesSchedule" not in text and "hydratePanelSnapshot" in text:
    text = text.replace(
        "readAccountFile, hydratePanelSnapshot } from \"./runtime-engvpn.mjs\";",
        "readAccountFile, hydratePanelSnapshot, syncUpdatesSchedule, engvpnScheduleUpdate } from \"./runtime-engvpn.mjs\";",
    )
elif "hydratePanelSnapshot" not in text and "engvpnParityInvoke" in text:
    text = text.replace(
        "engvpnParityInvoke, readAccountFile } from \"./runtime-engvpn.mjs\";",
        "engvpnParityInvoke, readAccountFile, hydratePanelSnapshot, syncUpdatesSchedule, engvpnScheduleUpdate } from \"./runtime-engvpn.mjs\";",
    )
elif "readSmartDns" not in text and "engvpnSmartDns" in text:
    text = text.replace(
        "engvpnSmartDns, engvpnBackup, mergeDiscoveredDevices, writeTransparentConf",
        "engvpnSmartDns, engvpnBackup, mergeDiscoveredDevices, readSmartDns, writeTransparentConf",
    )
elif "engvpnSmartDns" not in text:
    text = text.replace(
        "writeTransparentConf, modeFromRouter, engvpnParityInvoke, readAccountFile } from \"./runtime-engvpn.mjs\";",
        "engvpnSmartDns, engvpnBackup, mergeDiscoveredDevices, readSmartDns, writeTransparentConf, modeFromRouter, engvpnParityInvoke, readAccountFile, hydratePanelSnapshot } from \"./runtime-engvpn.mjs\";",
    )
elif "engvpnSaveAccount" not in text:
    text = text.replace(
        "writeTransparentConf, modeFromRouter, engvpnParityInvoke } from \"./runtime-engvpn.mjs\";",
        "engvpnDpi, engvpnWarp, engvpnSaveAccount, engvpnSyncAccount, engvpnSmartDns, engvpnBackup, mergeDiscoveredDevices, readSmartDns, writeTransparentConf, modeFromRouter, engvpnParityInvoke, readAccountFile, hydratePanelSnapshot } from \"./runtime-engvpn.mjs\";",
    )
needle = '      case "autoSetup":'
insert = '''      case "transparent":
        return engvpnTransparent(body.action || body.command || "status", body);
      case "transparentApply":
        return engvpnTransparent("apply", body);
      case "engvpnUpdateCheck":
      case "checkEngvpnUpdates":
        {
          const res = await engvpnUpdateCheck(state);
          saveState(state);
          return res;
        }
      case "engvpnScheduleUpdate":
      case "scheduleUpdate":
        return engvpnScheduleUpdate(body.action || body.command || "status", ...(body.args || []));
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
        "    if (!state.router) return { ok: true };\n"
        "    const mode = modeFromRouter(state.router.mode);\n"
        "    const dnsFlags = transparentDnsFlags(state);\n"
        "    const devices = selectedDeviceIds(state);\n"
        "    syncDevicesSelect(state);\n"
        "    writeTransparentConf({\n"
        "      mode,\n"
        "      killswitch: state.router.blockWithoutVpn ? \"1\" : \"0\",\n"
        "      method: state.router.transparentMethod || \"auto\",\n"
        "      ...dnsFlags,\n"
        "    });\n"
        "    if (mode !== \"off\" || dnsFlags.dns_hijack === \"1\" || dnsFlags.captive_open === \"1\") {\n"
        "      await engvpnTransparent(\"apply\", { mode, devices, ...dnsFlags });\n"
        "    } else {\n"
        "      await engvpnTransparent(\"stop\", {});\n"
        "    }\n"
        "    return { ok: true };\n"
        "  }\n\n"
        "  async function invoke(command, body = {}) {",
        1,
    )

# Hook router.mode / DNS / captive / DPI / updates patches — propagate failures + revert UI state
old_patch = '      case "patch":\n        return patch(body.path, body.value);'
new_patch = (
    '      case "patch": {\n'
    "        const path = body.path;\n"
    "        const parts = String(path || \"\").split(\".\").filter(Boolean);\n"
    "        let prev;\n"
    "        try {\n"
    "          let cur = state;\n"
    "          for (const p of parts) cur = cur?.[p];\n"
    "          prev = cur;\n"
    "        } catch { prev = undefined; }\n"
    "        const result = await patch(path, body.value);\n"
    "        const needsTransparent =\n"
    "          path === \"router.mode\" || path === \"router.transparentMethod\" || path === \"router.blockWithoutVpn\" ||\n"
    "          path === \"router.dnsViaVpn\" || path === \"router.dnsLock\" || path === \"router.adblock\" ||\n"
    "          path === \"router.trips\" || path === \"router.captive\";\n"
    "        try {\n"
    "          if (needsTransparent) {\n"
    "            if (path === \"router.transparentMethod\") writeTransparentConf({ method: body.value || \"auto\" });\n"
    "            if (path === \"router.blockWithoutVpn\") writeTransparentConf({ killswitch: body.value ? \"1\" : \"0\" });\n"
    "            await engvpnSyncTransparent();\n"
    "          }\n"
    "          if (path === \"network.youtubeZapret\" || path === \"network.discordZapret\") {\n"
    "            const want = !!(state.network?.youtubeZapret || state.network?.discordZapret);\n"
    "            await engvpnDpi(want ? \"apply\" : \"stop\", { enabled: want, youtube: !!state.network?.youtubeZapret, discord: !!state.network?.discordZapret });\n"
    "          }\n"
    "          if (typeof path === \"string\" && path.startsWith(\"updates.\")) {\n"
    "            const sched = await syncUpdatesSchedule(state);\n"
    "            if (sched && sched.ok === false) throw new Error(sched.error || \"Не удалось установить расписание обновлений\");\n"
    "          }\n"
    "        } catch (e) {\n"
    "          setPath(state, path, prev);\n"
    "          saveState(state);\n"
    "          const err = new Error(e.message || String(e));\n"
    "          err.status = 500;\n"
    "          throw err;\n"
    "        }\n"
    "        return result;\n"
    "      }"
)
if old_patch in text and 'engvpnSyncTransparent()' not in text.split('case "patch"')[1][:800]:
    text = text.replace(old_patch, new_patch, 1)
elif old_patch in text and 'needsTransparent' not in text:
    text = text.replace(old_patch, new_patch, 1)

# Sync Updates already folded into patch handler above when inserting fresh.
# If an older dpi-only hook exists without updates., extend it:
if "syncUpdatesSchedule" in text and 'path.startsWith("updates.")' not in text and "needsTransparent" not in text:
    needle_upd = '        if (body?.path === "network.youtubeZapret" || body?.path === "network.discordZapret") {'
    if needle_upd in text:
        text = text.replace(
            needle_upd,
            '        if (typeof body?.path === "string" && body.path.startsWith("updates.")) {\n'
            '          const sched = await syncUpdatesSchedule(state);\n'
            '          if (sched && sched.ok === false) throw new Error(sched.error || "Не удалось установить расписание обновлений");\n'
            '        }\n'
            '        if (body?.path === "network.youtubeZapret" || body?.path === "network.discordZapret") {',
            1,
        )

# Override alfa checkUpdates stub → real feed check + schedule stamp
if 'return await engvpnUpdateCheck(state)' not in text and 'case "checkUpdates":' in text:
    import re as _re_chk
    text2, n_chk = _re_chk.subn(
        r'case "checkUpdates":\s*state\.updates\.lastCheck = Date\.now\(\);\s*'
        r'state\.updates\.latest = state\.version;\s*saveState\(state\);\s*'
        r'return \{ ok: true, latest: state\.version, message: "[^"]*" \};',
        'case "checkUpdates": {\n'
        '        const res = await engvpnUpdateCheck(state);\n'
        '        saveState(state);\n'
        '        return res;\n'
        '      }',
        text,
        count=1,
    )
    if n_chk:
        text = text2
        print("patched checkUpdates → engvpnUpdateCheck")

# Enrich snapshot with account/transparent/smartdns + one-shot LAN discover
import re as _re
if "hydratePanelSnapshot(" not in text:
    m = _re.search(r"function snapshot\(\)\s*\{.*?^\s*(return publicState\([^;]+;)", text, _re.S | _re.M)
    if m:
        ret = m.group(1)
        replacement = (
            "const __snap = " + ret[len("return "):].rstrip(";") + ";\n"
            "    try { hydratePanelSnapshot(__snap, state); } catch { /* ignore */ }\n"
            "    try { if (!__snap.smartdns) __snap.smartdns = readSmartDns(); } catch { __snap.smartdns = { enabled: false, entries: [] }; }\n"
            "    try {\n"
            "      const onlyDemo = !(state.devices || []).length || (state.devices || []).every((d) => d.demo);\n"
            "      if (onlyDemo) mergeDiscoveredDevices(state);\n"
            "    } catch { /* ignore */ }\n"
            "    return __snap;"
        )
        text = text[: m.start(1)] + replacement + text[m.end(1) :]
        print("patched snapshot() with account hydrate + smartdns + discover")
elif "__snap.smartdns" in text and "hydratePanelSnapshot(" not in text:
    text = text.replace(
        "    try { __snap.smartdns = readSmartDns(); } catch { __snap.smartdns = { enabled: false, entries: [] }; }\n",
        "    try { hydratePanelSnapshot(__snap, state); } catch { /* ignore */ }\n"
        "    try { if (!__snap.smartdns) __snap.smartdns = readSmartDns(); } catch { __snap.smartdns = { enabled: false, entries: [] }; }\n",
        1,
    )
    print("patched snapshot() to hydrate account/transparent")

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
        "        await engvpnSyncTransparent();\n"
        "        return snapshot();\n"
        "      }\n"
        "      if (parity && typeof parity.then === \"function\") return parity;\n"
        "      return parity;\n"
        "    }\n"
        "    switch (command) {",
        1,
    )
# Override stub leakTest → real EngVPN privacy checks (+ aliases)
if "engvpnPrivacyCheck(state" not in text:
    text = text.replace(
        '      case "leakTest":\n        return leakTest();',
        '      case "leakTest":\n'
        '      case "privacyCheck":\n'
        '      case "stealthCheck":\n'
        '      case "engvpnPrivacy":\n'
        '        return engvpnPrivacyCheck(state, { httpPort: live.httpPort, socksPort: live.socksPort, action: body?.action || "all" });',
        1,
    )
# Ensure import includes engvpnPrivacyCheck on rebuild
if "engvpnPrivacyCheck" not in text and "from \"./runtime-engvpn.mjs\"" in text:
    text = text.replace(
        "engvpnDpi, engvpnWarp,",
        "engvpnDpi, engvpnWarp, engvpnPrivacyCheck,",
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
# Hook zapret recheck → also apply open DPI when youtube/discord zapret enabled (fail loudly)
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
        "    const want = !!(state.network.youtubeZapret || state.network.discordZapret);\n"
        "    const dpiRes = await engvpnDpi(want ? \"apply\" : \"stop\", { enabled: want, youtube: !!state.network.youtubeZapret, discord: !!state.network.discordZapret });\n"
        "    state.network.zapret.note = want ? (dpiRes?.output || \"DPI nfqws apply\") : \"DPI stop\";\n"
        "    ctx.hooks.log(\"info\", want ? \"DPI nfqws: apply\" : \"DPI nfqws: stop\");\n"
        "    ctx.hooks.log(\"info\", all ? \"Проверка способов завершена + DPI\" : \"Прямые пути + DPI\");\n"
        "    if (state.vpn.connected) await connect();\n"
        "    else saveState(state);\n"
        "    return snapshot();\n"
        "  }",
        1,
    )
# Honest zapret method note (open nfqws, not proprietary SS strategies)
if "Подмена пакетов на этом стенде не выполняется" in text:
    text = text.replace(
        "Подмена пакетов на этом стенде не выполняется.",
        "EngVPN: способ выбирает прямой/VPN; реальный mangling — open zapret/nfqws (dpi.sh), не стратегии StealthSurf.",
    )
# Wire deviceSet → devices.select + transparent re-apply for selected/exclude
if "syncDevicesSelect(state)" not in text.split("function deviceSet")[1][:600] if "function deviceSet" in text else True:
    old_ds = (
        "  function deviceSet(body) {\n"
        "    const device = ensureDevice(body);\n"
        "    if (body.excluded != null) device.excluded = Boolean(body.excluded);\n"
        "    if (body.route) device.route = body.route;\n"
        "    if (body.configId) device.configId = body.configId;\n"
        "    if (Array.isArray(body.bypass)) device.bypass = body.bypass;\n"
        "    if (body.online != null) device.online = Boolean(body.online);\n"
        "    saveState(state);\n"
        "    return snapshot();\n"
        "  }"
    )
    new_ds = (
        "  async function deviceSet(body) {\n"
        "    const device = ensureDevice(body);\n"
        "    if (body.excluded != null) device.excluded = Boolean(body.excluded);\n"
        "    if (body.route) device.route = body.route;\n"
        "    if (body.configId) device.configId = body.configId;\n"
        "    if (Array.isArray(body.bypass)) device.bypass = body.bypass;\n"
        "    if (body.online != null) device.online = Boolean(body.online);\n"
        "    saveState(state);\n"
        "    syncDevicesSelect(state);\n"
        "    const mode = modeFromRouter(state.router?.mode);\n"
        "    if (mode === \"selected\" || mode === \"exclude\") {\n"
        "      await engvpnTransparent(\"apply\", { mode, devices: selectedDeviceIds(state), ...transparentDnsFlags(state) });\n"
        "    }\n"
        "    return snapshot();\n"
        "  }"
    )
    if old_ds in text:
        text = text.replace(old_ds, new_ds, 1)
        print("patched deviceSet → devices.select sync")
# Ensure syncDevicesSelect imported even if primary import already existed
if "syncDevicesSelect" not in text and "from \"./runtime-engvpn.mjs\"" in text:
    text = text.replace(
        "hydratePanelSnapshot, syncUpdatesSchedule } from \"./runtime-engvpn.mjs\";",
        "hydratePanelSnapshot, syncUpdatesSchedule, syncDevicesSelect, selectedDeviceIds, transparentDnsFlags } from \"./runtime-engvpn.mjs\";",
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
# SmartDNS domain/IP bypass: merge data/run/bypass.routing.json into engine rules
if "smartdnsBypassRules" not in et:
    helper = r'''
function smartdnsBypassRules() {
  try {
    const path = join(DATA, "run", "bypass.routing.json");
    if (!existsSync(path)) return [];
    const doc = JSON.parse(readFileSync(path, "utf8"));
    if (!doc || doc.enabled === false) return [];
    const domains = [];
    const ips = [];
    for (const r of doc.rules || []) {
      for (const d of r.domain || []) {
        const s = String(d).replace(/^domain:/, "").replace(/^full:/, "").trim();
        if (s) domains.push(s);
      }
      for (const ip of r.ip || []) if (ip) ips.push(String(ip));
    }
    const domFile = join(DATA, "run", "bypass.domains");
    const ipFile = join(DATA, "run", "bypass.ips");
    if (existsSync(domFile)) {
      for (const line of readFileSync(domFile, "utf8").split("\n")) {
        const t = line.trim();
        if (t && !t.startsWith("#")) domains.push(t);
      }
    }
    if (existsSync(ipFile)) {
      for (const line of readFileSync(ipFile, "utf8").split("\n")) {
        const t = line.trim();
        if (t && !t.startsWith("#")) ips.push(t);
      }
    }
    const uniqDom = [...new Set(domains)];
    const uniqIp = [...new Set(ips)];
    if (!uniqDom.length && !uniqIp.length) return [];
    return [{ id: "smartdns-bypass", action: "direct", reason: "SmartDNS bypass", match: { suffixes: uniqDom, cidrs: uniqIp } }];
  } catch {
    return [];
  }
}

'''
    if "function domainStrategy(state)" in et:
        et = et.replace("function domainStrategy(state)", helper + "function domainStrategy(state)", 1)
    et = et.replace(
        "const rules = tunnelOnly ? [] : ruleList(state).map(xrayRule).filter(Boolean);",
        "const rules = tunnelOnly ? [] : [...smartdnsBypassRules(), ...ruleList(state)].map(xrayRule).filter(Boolean);",
        1,
    )
    et = et.replace(
        "const rules = tunnelOnly || plan.reject ? [] : ruleList(state).map(singRule).filter(Boolean);",
        "const rules = tunnelOnly || plan.reject ? [] : [...smartdnsBypassRules(), ...ruleList(state)].map(singRule).filter(Boolean);",
        1,
    )
    et = et.replace(
        'const rules = tunnelOnly ? ["  - MATCH,PROXY"] : ruleList(state).flatMap(mihomoRule);',
        'const rules = tunnelOnly ? ["  - MATCH,PROXY"] : [...smartdnsBypassRules(), ...ruleList(state)].flatMap(mihomoRule);',
        1,
    )
    print("patched engines.mjs SmartDNS bypass merge")
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

# Reproducible archives: fixed mtime + gzip -n so rebuild SHA matches the feed.
pack_one() {
	arch=$1
	name="engvpn_${VERSION}_${arch}.tar.gz"
	# GNU tar: stable order/ownership; BusyBox fallback keeps gzip -n only.
	if tar --help 2>&1 | grep -q -- '--mtime'; then
		tar -C "$STAGE" --sort=name --mtime='UTC 2020-01-01' --owner=0 --group=0 --numeric-owner -cf - . |
			gzip -n >"$OUT/$name"
	else
		tar -C "$STAGE" -cf - . | gzip -n >"$OUT/$name"
	fi
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

# Local file:// feed for smoke; also write relative GitHub-style URLs for docs.
# Use spaces only (no tabs): older merlin.sh/update.sh sed matched /^  "version"/.
FEED=$ROOT/feed/latest.json
cat >"$FEED" <<EOF
{
  "version": "$VERSION",
  "notes": "EngVPN $VERSION — iOS login keyboard fix; optional skip panel password on install.",
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
  "notes": "EngVPN $VERSION — iOS login keyboard fix; optional skip panel password on install.",
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
