const EXT = "/ext/stealthsurf";
// Mirror XrayUI Version.vue: read-only GitHub lookups happen in the browser.
// Never route listversions/checkupdate through Merlin start_apply.htm.
const SS_GH_REPO = "Homavi88/Stealthsurf-Asus";
const SS_GH_RELEASES_API = "https://api.github.com/repos/" + SS_GH_REPO + "/releases";
const SS_GH_LATEST_API = SS_GH_RELEASES_API + "/latest";
const SS_RELEASE_ASSET = "asuswrt-merlin-stealthsurf.tar.gz";
const SS_RELEASES_TO_SHOW = 15;

// Do not bind a global `$`. Merlin show_menu() needs jQuery `$` (inArray, #tabMenu)
// before it paints #mainMenu. Shadowing `$` leaves the left router menu empty.
function byId(id) {
  return document.getElementById(id);
}

const PROTO_OPTIONS = [
  "vless",
  "vless-2410",
  "trojan",
  "trojan-2901",
  "shadowsocks-2022",
  "hysteria2",
  "wg",
  "amnezia-wg-2",
  "openflux",
  "http",
  "socks5",
];

let stateCache = null;
let configsCache = [];
let outboundsCache = { enabled: [], default: "" };
let routingCache = { rules: [] };
let policiesCache = { catchall: true, rules: [] };
let protocolsCache = {};
let clientsCache = [];
let versionCache = { installed: "—", latest: null, update_available: false };
let versionsCache = { installed: "—", releases: [] };
let selectedRelease = null;

function setMsg(text, kind) {
  const el = byId("msg");
  el.textContent = text || "";
  el.className = "ss-msg" + (kind ? " " + kind : "");
}

async function fetchJson(url) {
  const res = await fetch(url + (url.includes("?") ? "&" : "?") + "_=" + Date.now(), {
    cache: "no-store",
  });
  if (!res.ok) throw new Error(url + " HTTP " + res.status);
  return res.json();
}

async function fetchGithubJson(url) {
  // Same idea as XrayUI engine.fetchGithubJson — direct browser GET to api.github.com
  const res = await fetch(url, {
    cache: "no-store",
    headers: {
      Accept: "application/vnd.github+json",
      "User-Agent": "stealthsurf-merlin-webui",
    },
  });
  if (!res.ok) throw new Error("GitHub HTTP " + res.status);
  return res.json();
}

function versionNormalize(v) {
  return String(v || "")
    .replace(/^[vV]/, "")
    .replace(/[^0-9.].*$/, "");
}

function versionCmp(a, b) {
  const pa = versionNormalize(a)
    .split(".")
    .map((n) => parseInt(n, 10) || 0);
  const pb = versionNormalize(b)
    .split(".")
    .map((n) => parseInt(n, 10) || 0);
  const len = Math.max(pa.length, pb.length);
  for (let i = 0; i < len; i++) {
    const x = pa[i] || 0;
    const y = pb[i] || 0;
    if (x > y) return 1;
    if (x < y) return -1;
  }
  return 0;
}

function cleanChangelogBullet(line) {
  return String(line || "")
    .replace(/^[*#-]+\s*/, "")
    .replace(/\*\*([^*]+)\*\*/g, "$1")
    .replace(/`([^`]+)`/g, "$1")
    .replace(/\s+by @[A-Za-z0-9_-]+(\s+in\s+(#[0-9]+|https?:\/\/\S+))?\s*$/i, "")
    .replace(/\s+\(#[0-9]+\)\s*$/, "")
    .replace(/\s+in https?:\/\/\S+/i, "")
    .replace(/^docs:\s*/i, "Документация: ")
    .replace(/^fix:\s*/i, "Исправление: ")
    .replace(/^feat(\([^)]*\))?:\s*/i, "Новое: ")
    .replace(/^chore(\([^)]*\))?:\s*/i, "")
    .replace(/^ci(\([^)]*\))?:\s*/i, "CI: ")
    .replace(/^Release v[0-9.]+\s*:\s*/i, "")
    .trim();
}

function classifyChangelogLine(line) {
  const s = String(line || "");
  if (!s) return "skip";
  if (/what.?s changed|full changelog|new contributors|^---+$/i.test(s)) return "skip";
  if (/release v[0-9]|merge pull request|bump version|ship main/i.test(s)) return "skip";
  if (/fix|bug|crash|ошибк|исправ|blackhole|конфликт|conflict|broken|не работ/i.test(s)) return "fixes";
  if (/feat|added|\badd\b|новое|добав|modal|screenshot|\bcli\b|баннер|guard|\bblock\b|блок|xrayui|оптимиз|optim|performance|\bcpu\b|memory|\bram\b|\bui\b|webui|changelog|human/i.test(s))
    return "features";
  if (/docs|readme|документац|chore|\bci\b|workflow/i.test(s)) return "other";
  return "other";
}

function humanizeChangelog(body, tag, name) {
  const features = [];
  const fixes = [];
  const other = [];
  const seen = {};
  String(body || "")
    .split(/\r?\n/)
    .forEach((raw) => {
      const line = String(raw || "");
      if (/^#{1,3}\s/.test(line)) return;
      if (!/^[\*\-]\s+/.test(line) && !/^[0-9]+\.\s+/.test(line)) return;
      const cleaned = cleanChangelogBullet(line);
      if (!cleaned || cleaned.length < 8 || seen[cleaned]) return;
      seen[cleaned] = 1;
      const kind = classifyChangelogLine(cleaned);
      if (kind === "fixes") fixes.push(cleaned);
      else if (kind === "features") features.push(cleaned);
      else if (kind === "other") other.push(cleaned);
    });
  const featN = features.length;
  const fixN = fixes.length;
  let headline = name || tag || "Релиз";
  if (featN && fixN) headline = "Новые возможности и исправления ошибок";
  else if (featN) headline = "Новые возможности";
  else if (fixN) headline = "Исправления ошибок";
  const summaryParts = [];
  if (featN) summaryParts.push("новое: " + featN);
  if (fixN) summaryParts.push("исправления: " + fixN);
  if (other.length) summaryParts.push("ещё: " + other.length);
  return {
    headline: headline,
    summary: summaryParts.length ? summaryParts.join(" · ") : headline,
    features: features.slice(0, 12),
    fixes: fixes.slice(0, 12),
    other: other.slice(0, 8),
  };
}

function assetUrlFromGithubRelease(rel, tag) {
  const assets = (rel && rel.assets) || [];
  for (let i = 0; i < assets.length; i++) {
    if (assets[i] && assets[i].name === SS_RELEASE_ASSET && assets[i].browser_download_url) {
      return assets[i].browser_download_url;
    }
  }
  if (tag) {
    return "https://github.com/" + SS_GH_REPO + "/releases/download/" + tag + "/" + SS_RELEASE_ASSET;
  }
  return "https://github.com/" + SS_GH_REPO + "/releases/latest/download/" + SS_RELEASE_ASSET;
}

function mapGithubRelease(rel, installed) {
  if (!rel || rel.draft || !rel.tag_name) return null;
  const tag = String(rel.tag_name);
  const version = versionNormalize(tag);
  const cmp = versionCmp(version, installed || "0");
  const direction = cmp > 0 ? "newer" : cmp < 0 ? "older" : "same";
  return {
    tag: tag,
    version: version || null,
    name: rel.name || null,
    release_url: rel.html_url || null,
    download_url: assetUrlFromGithubRelease(rel, tag),
    published_at: rel.published_at || rel.created_at || null,
    prerelease: !!rel.prerelease,
    direction: direction,
    current: direction === "same",
    changelog: humanizeChangelog(rel.body || "", tag, rel.name || ""),
  };
}

function buildVersionsFromGithubList(list, installed) {
  const releases = [];
  (Array.isArray(list) ? list : []).forEach((rel) => {
    const entry = mapGithubRelease(rel, installed);
    if (entry) releases.push(entry);
  });
  return {
    installed: installed || "—",
    repo: SS_GH_REPO,
    checked_at: Math.floor(Date.now() / 1000),
    error: null,
    releases: releases.slice(0, SS_RELEASES_TO_SHOW),
  };
}

function buildVersionInfoFromGithubLatest(latestRel, installed) {
  const entry = mapGithubRelease(latestRel, installed);
  const latest = entry && entry.version ? entry.version : null;
  const upd = !!(latest && installed && versionCmp(latest, installed) > 0);
  return {
    installed: installed || "—",
    latest: latest,
    tag: entry && entry.tag ? entry.tag : null,
    release_url: entry && entry.release_url ? entry.release_url : null,
    download_url: entry && entry.download_url ? entry.download_url : null,
    update_available: upd,
    repo: SS_GH_REPO,
    checked_at: Math.floor(Date.now() / 1000),
    error: null,
    changelog: entry && entry.changelog ? entry.changelog : null,
  };
}

function installedVersionHint() {
  return (
    (versionCache && versionCache.installed && versionCache.installed !== "—" && versionCache.installed) ||
    (stateCache && stateCache.version) ||
    (byId("installedVer") && byId("installedVer").textContent.replace(/^v/, "")) ||
    "—"
  );
}

function setVersionsModalStatus(kind, text) {
  const el = byId("versionsStatus");
  if (!el) return;
  el.textContent = text || "";
  el.className = "ss-versions-status" + (kind ? " " + kind : "");
  el.style.display = text ? "block" : "none";
}

function buildAmngCustom(payload) {
  // Merlin write_custom_settings() only stores FLAT string values in
  // /jffs/addons/custom_settings.txt (json_object_get_string). Nested objects
  // like {stealthsurf:{api_key:...}} become null/empty — setkey never saw the key.
  // Also: httpd never nvram_set("amng_custom"), so nvram get is always empty.
  // Mirror XrayUI: store the action JSON as a string under stealthsurf_payload
  // (chunked if needed), and merge other addons' existing custom_settings keys.
  let base = {};
  try {
    if (typeof custom_settings === "object" && custom_settings) {
      base = JSON.parse(JSON.stringify(custom_settings));
    }
  } catch (_) {
    base = {};
  }
  Object.keys(base).forEach((k) => {
    if (k === "stealthsurf" || k === "stealthsurf_payload" || /^stealthsurf_payload\d+$/.test(k)) {
      delete base[k];
    }
  });
  const raw = JSON.stringify(payload || {});
  // Merlin value line buffer ~3040; keep chunks safely under that
  const CHUNK = 2800;
  if (raw.length <= CHUNK) {
    base.stealthsurf_payload = raw;
  } else {
    let i = 0;
    for (let off = 0; off < raw.length; off += CHUNK) {
      base["stealthsurf_payload" + i] = raw.slice(off, off + CHUNK);
      i += 1;
    }
  }
  let blob = JSON.stringify(base);
  // Whole custom_settings.txt repo is ~8KB; if merge is too big, send payload-only
  if (blob.length > 7500) {
    const slim = {};
    Object.keys(base).forEach((k) => {
      if (k === "stealthsurf_payload" || /^stealthsurf_payload\d+$/.test(k)) slim[k] = base[k];
    });
    blob = JSON.stringify(slim);
  }
  return blob;
}

function triggerService(action, payload, opts) {
  const data = payload || {};
  const options = opts || {};
  // Hard-block destructive actions from the browser — CLI only
  if (action === "uninstall" || action === "remove" || action === "purge") {
    setMsg("Удаление из WebUI отключено. В SSH: ssurf un --yes (или сначала ssurf doctor)", "err");
    return;
  }
  // Read-only GitHub lookups must NOT hijack Merlin start_apply / percent progress.
  // Mirror XrayUI: browser fetch → modal; only install/update uses form submit.
  if (action === "checkupdate") {
    checkUpdateFromGithub({ openModalIfUpdate: true });
    return;
  }
  if (action === "listversions" || action === "versions") {
    requestVersionsList(true);
    return;
  }
  // Update downloads a release — needs a longer httpd wait / refresh
  let wait = Number(options.wait || 0);
  if (!wait) {
    if (action === "update" || action === "upgrade" || action === "installversion" || action === "switchversion" || action === "rollback") wait = 40;
    else if (action === "installxray" || action === "sync") wait = 20;
    else if (action === "backup" || action === "restore") wait = 15;
    else if (action === "logs" || action === "devicesnapshot" || action === "clearlogs") wait = 12;
    else wait = 10;
  }

  try {
    sessionStorage.setItem("ss_payload", JSON.stringify(data));
  } catch (_) {}

  const form = document.form || byId("ruleForm");
  if (!form) {
    setMsg("Форма действия не найдена", "err");
    return;
  }

  const blob = buildAmngCustom(data);
  // Merlin custom_settings.txt whole-file limit ~8KB
  if (blob.length > 7800) {
    setMsg(
      "Payload слишком большой (" + blob.length + " байт). Упростите routing/policies или правьте через CLI.",
      "err"
    );
    return;
  }
  byId("ss_payload_field").value = blob;

  const page = (location.pathname || "").replace(/^\//, "") || "user1.asp";
  if (form.current_page) form.current_page.value = page;
  if (form.next_page) form.next_page.value = page;
  // Merlin: start_NAME → service-event $1=start $2=NAME.
  // Without start_, $1 is empty; our hook still matches $2, but start_ is the stock path.
  form.action_script.value = "start_stealthsurf_" + action;
  form.action_mode.value = "apply";
  form.action_wait.value = String(wait);

  const labels = {
    installversion: "Установка выбранной версии с GitHub…",
    switchversion: "Переключение версии с GitHub…",
    rollback: "Откат на выбранную версию…",
    update: "Установка обновления с GitHub (скачивание)…",
    upgrade: "Установка обновления с GitHub…",
    start: "Запуск…",
    stop: "Остановка…",
    restart: "Рестарт…",
    backup: "Создание backup…",
    backuplist: "Обновление списка backup…",
    restore: "Восстановление из backup…",
    logs: "Чтение логов…",
    devicesnapshot: "Снимок устройств LAN…",
    clearlogs: "Очистка логов…",
    setsettings: "Сохранение настроек…",
    getsettings: "Загрузка настроек…",
    geodata: "Обновление geoip/geosite…",
  };
  setMsg(labels[action] || "Выполняется: " + action + "…", "");
  if (typeof showLoading === "function") showLoading();
  form.submit();
  setTimeout(() => refreshAll(), Math.max(3000, wait * 1000 - 1000));
}

const SS_SECTION_MODALS = {
  keys: "keysModal",
  catalog: "catalogModal",
  routing: "routingModal",
  policies: "policiesModal",
  general: "generalModal",
  backup: "backupModal",
  diag: "diagModal",
  settings: "settingsModal",
  versions: "versionsModal",
};

function openSsModal(id) {
  const modal = byId(id);
  if (!modal) return;
  // One section modal at a time (keep update banner modals independent)
  Object.values(SS_SECTION_MODALS).forEach((mid) => {
    if (mid === id) return;
    if (mid === "settingsModal" || mid === "versionsModal") return;
    const el = byId(mid);
    if (el) el.classList.remove("show");
  });
  modal.classList.add("show");
}

function closeSsModal(id) {
  const modal = byId(id);
  if (modal) modal.classList.remove("show");
}

function switchTab(name) {
  // XrayUI-style: sections open in dedicated modals (not a long stacked page)
  document.querySelectorAll(".ss-tab").forEach((t) => {
    t.classList.toggle("active", t.dataset.tab === name);
  });
  const modalId = SS_SECTION_MODALS[name];
  if (modalId === "settingsModal") {
    openSettingsModal();
    return;
  }
  if (modalId === "versionsModal") {
    openVersionsModal(versionsCache);
    requestVersionsList(false);
    return;
  }
  if (name === "catalog" || name === "outbounds") {
    const panel = byId("sec-outbounds");
    if (panel && typeof panel.scrollIntoView === "function") {
      panel.scrollIntoView({ behavior: "smooth", block: "start" });
    }
    return;
  }
  if (modalId) {
    openSsModal(modalId);
    return;
  }
  const panel = byId("tab-" + name) || document.getElementById("sec-" + name);
  if (panel && typeof panel.scrollIntoView === "function") {
    panel.scrollIntoView({ behavior: "smooth", block: "start" });
  }
}

function updateSectionSummaries() {
  const set = (id, text) => {
    const el = byId(id);
    if (el) el.textContent = text;
  };
  const keysN = (byId("keysTable") && byId("keysTable").children.length) || 0;
  set("sumKeys", "ключей: " + keysN);
  const cfgN = (configsCache || []).length;
  const enN = enabledSet().size;
  set("sumCatalog", "конфигов: " + cfgN + " · outbound: " + enN);
  const rulesN =
    (routingCache && Array.isArray(routingCache.rules) && routingCache.rules.length) ||
    (byId("rulesTable") && byId("rulesTable").children.length) ||
    0;
  set("sumRouting", "правил: " + rulesN);
  const polN =
    (policiesCache && Array.isArray(policiesCache.rules) && policiesCache.rules.length) ||
    (byId("policiesTable") && byId("policiesTable").children.length) ||
    0;
  set("sumPolicies", "политик: " + polN);
  const mode = (stateCache && (stateCache.proxy_mode || stateCache.mode)) || "—";
  const dns = (stateCache && stateCache.dns_mode) || "—";
  set("sumGeneral", "mode: " + mode + " · dns: " + dns);
}

function btnClass(kind) {
  // Native Merlin buttons; kind kept for API compatibility
  return "button_gen button_gen_small";
}

function labelClass(kind) {
  if (kind === "on" || kind === "ok" || kind === "success") return "label label-success";
  if (kind === "off" || kind === "err" || kind === "error") return "label label-error";
  if (kind === "warn" || kind === "update" || kind === "warning") return "label label-warning";
  return "label label-muted";
}

function xrayuiInfo(state) {
  if (!state) return { installed: false, running: false, message: "" };
  const xu = state.xrayui || {};
  const running = !!(xu.running || state.conflict === "xrayui");
  const installed = !!(xu.installed || running);
  const message =
    xu.message ||
    state.conflict_message ||
    (running
      ? "XrayUI сейчас работает. Остановите XrayUI, затем запускайте StealthSurf."
      : "");
  return { installed, running, message };
}

function renderConflict(state) {
  const info = xrayuiInfo(state);
  const banner = byId("conflictBanner");
  const conflictPill = byId("conflictPill");
  const xrayuiPill = byId("xrayuiPill");
  const btnStart = byId("btnStart");
  const btnRestart = byId("btnRestart");

  if (banner) {
    if (info.running) {
      banner.classList.add("show");
      if (byId("conflictText") && info.message) byId("conflictText").textContent = info.message;
    } else {
      banner.classList.remove("show");
    }
  }

  if (conflictPill) {
    if (info.running) {
      conflictPill.style.display = "inline-block";
      conflictPill.className = labelClass("err");
      conflictPill.textContent = "XrayUI конфликт";
    } else {
      conflictPill.style.display = "none";
    }
  }

  if (xrayuiPill) {
    if (info.installed && !info.running) {
      xrayuiPill.style.display = "inline-block";
      xrayuiPill.className = labelClass("warn");
      xrayuiPill.textContent = "XrayUI установлен (остановлен)";
    } else {
      xrayuiPill.style.display = "none";
    }
  }

  if (btnStart) btnStart.disabled = !!info.running;
  if (btnRestart) btnRestart.disabled = !!info.running;
}

function renderState(state) {
  if (!state) return;
  stateCache = state;
  const running = !!state.running;
  const pill = byId("runState");
  pill.textContent = running ? "StealthSurf is running" : "StealthSurf is stopped";
  pill.className = labelClass(running ? "on" : "off");
  // XrayUI pattern: start XOR restart+stop
  if (byId("btnStart")) byId("btnStart").style.display = running ? "none" : "inline-block";
  if (byId("btnRestart")) byId("btnRestart").style.display = running ? "inline-block" : "none";
  if (byId("btnStop")) byId("btnStop").style.display = running ? "inline-block" : "none";
  byId("activeCfg").textContent = "active: " + (state.active_config_id ?? "—");
  byId("modePill").textContent = "mode: " + (state.proxy_mode || state.mode || "—");
  byId("ports").textContent =
    "socks :" +
    (state.socks_port || "—") +
    " / http :" +
    (state.http_port || "—") +
    " / tp :" +
    (state.tproxy_port || state.redirect_port || "—");
  byId("defaultPill").textContent = "default: " + (state.default_outbound || "—");
  if (state.mode && byId("modeSelect")) byId("modeSelect").value = state.mode;
  if (state.dns_mode && byId("dnsModeSelect")) byId("dnsModeSelect").value = state.dns_mode;
  if (state.version) {
    if (byId("installedVer")) byId("installedVer").textContent = "v" + state.version;
    if (byId("titleVer")) byId("titleVer").textContent = "v" + state.version;
    if (byId("footerVer")) byId("footerVer").textContent = "v" + state.version;
  }
  renderConflict(state);
}

function fillModalList(ulId, boxId, items) {
  const ul = byId(ulId);
  const box = byId(boxId);
  if (!ul || !box) return;
  ul.innerHTML = "";
  const list = Array.isArray(items) ? items.filter(Boolean) : [];
  if (!list.length) {
    box.style.display = "none";
    return;
  }
  list.forEach((text) => {
    const li = document.createElement("li");
    li.textContent = text;
    ul.appendChild(li);
  });
  box.style.display = "block";
}

function updateNoticeTag(info) {
  return String((info && (info.tag || info.latest)) || "").replace(/^v/i, "") || "";
}

function updateDismissKey(info) {
  return "ss_update_dismiss_" + updateNoticeTag(info);
}

function updateLaterKey(info) {
  return "ss_update_later_" + updateNoticeTag(info);
}

/** True if auto-popup should show for this release (respect Later / Close). */
function shouldAutoShowUpdateModal(info) {
  if (!info || !info.update_available) return false;
  const tag = updateNoticeTag(info);
  if (!tag) return false;
  try {
    if (localStorage.getItem(updateDismissKey(info)) === "1") return false;
    if (sessionStorage.getItem(updateLaterKey(info)) === "1") return false;
  } catch (_) {}
  return true;
}

function snoozeUpdateNotice(info) {
  // «Обновить позднее» — скрыть до следующего захода в WebUI (эта сессия браузера)
  try {
    sessionStorage.setItem(updateLaterKey(info || versionCache), "1");
  } catch (_) {}
  closeUpdateModal();
  setMsg("Напомним об обновлении при следующем открытии страницы", "");
}

function dismissUpdateNotice(info) {
  // «Закрыть уведомление» — не показывать снова для этой версии
  try {
    localStorage.setItem(updateDismissKey(info || versionCache), "1");
  } catch (_) {}
  closeUpdateModal();
  setMsg("Уведомление об этой версии скрыто. Баннер и кнопка Update остаются доступны.", "");
}

function openUpdateModal(info, opts) {
  const data = info || versionCache || {};
  const modal = byId("updateModal");
  if (!modal) return;
  const options = opts || {};
  const cl = data.changelog || {};
  const latest = data.latest || data.tag || "—";
  const installed = data.installed || "—";

  if (byId("modalLatest")) byId("modalLatest").textContent = latest;
  if (byId("modalSummary")) {
    byId("modalSummary").textContent =
      cl.summary ||
      cl.headline ||
      ("Сейчас установлена версия " +
        installed +
        ". На GitHub доступна " +
        latest +
        ". Можно обновить сейчас, отложить напоминание или закрыть уведомление.");
  }
  fillModalList("modalFeatures", "modalFeatBox", cl.features);
  fillModalList("modalFixes", "modalFixBox", cl.fixes);
  fillModalList("modalOther", "modalOtherBox", cl.other);

  const link = byId("modalGhLink");
  if (link) {
    if (data.release_url) {
      link.href = data.release_url;
      link.style.display = "inline";
    } else if (data.repo) {
      link.href = "https://github.com/" + data.repo + "/releases/latest";
      link.style.display = "inline";
    } else {
      link.href = "#";
      link.style.display = "none";
    }
  }

  modal.classList.add("show");
  if (options.markAutoShown) {
    // remember we already auto-opened once this session for this tag (extra guard)
    try {
      sessionStorage.setItem("ss_update_autoshown_" + updateNoticeTag(data), "1");
    } catch (_) {}
  }
}

function closeUpdateModal() {
  const modal = byId("updateModal");
  if (modal) modal.classList.remove("show");
}

function directionLabel(dir) {
  if (dir === "newer") return { text: "новее (обновление)", cls: "newer" };
  if (dir === "older") return { text: "старше (откат)", cls: "older" };
  if (dir === "same") return { text: "текущая", cls: "same" };
  return { text: "—", cls: "" };
}

function findReleaseByTag(tag) {
  const list = (versionsCache && versionsCache.releases) || [];
  return list.find((r) => r && (r.tag === tag || r.version === tag)) || null;
}

function renderSelectedRelease(rel) {
  selectedRelease = rel || null;
  const badge = byId("versionDirection");
  const summary = byId("versionPickSummary");
  const btn = byId("btnVersionInstall");
  const link = byId("versionGhLink");
  if (!rel) {
    if (badge) {
      badge.textContent = "—";
      badge.className = "ss-version-badge";
    }
    if (summary) summary.textContent = "Выберите версию в списке.";
    fillModalList("verFeatures", "verFeatBox", []);
    fillModalList("verFixes", "verFixBox", []);
    fillModalList("verOther", "verOtherBox", []);
    if (btn) {
      btn.disabled = true;
      btn.value = "Установить выбранную";
    }
    if (link) link.style.display = "none";
    return;
  }
  const cl = rel.changelog || {};
  const dir = directionLabel(rel.direction);
  if (badge) {
    badge.textContent = dir.text;
    badge.className = "ss-version-badge" + (dir.cls ? " " + dir.cls : "");
  }
  if (summary) {
    summary.textContent =
      cl.summary ||
      cl.headline ||
      ("Релиз " + (rel.tag || rel.version || "") + (rel.name ? " — " + rel.name : "") + ".");
  }
  fillModalList("verFeatures", "verFeatBox", cl.features);
  fillModalList("verFixes", "verFixBox", cl.fixes);
  fillModalList("verOther", "verOtherBox", cl.other);
  if (btn) {
    btn.disabled = false;
    if (rel.direction === "older") btn.value = "Откатиться на " + (rel.tag || rel.version);
    else if (rel.direction === "newer") btn.value = "Обновить до " + (rel.tag || rel.version);
    else btn.value = "Переустановить " + (rel.tag || rel.version);
  }
  if (link) {
    if (rel.release_url) {
      link.href = rel.release_url;
      link.style.display = "inline";
    } else {
      link.href = "#";
      link.style.display = "none";
    }
  }
}

function fillVersionsSelect(data) {
  const sel = byId("versionSelect");
  if (!sel) return;
  const releases = (data && data.releases) || [];
  const installed = (data && data.installed) || (versionCache && versionCache.installed) || "—";
  if (byId("versionsInstalled")) byId("versionsInstalled").textContent = installed !== "—" ? "v" + installed : "—";
  sel.innerHTML = "";
  if (!releases.length) {
    const o = document.createElement("option");
    o.value = "";
    o.textContent = data && data.error ? "Ошибка: " + data.error : "Нет релизов (нажмите «Обновить список»)";
    sel.appendChild(o);
    renderSelectedRelease(null);
    return;
  }
  releases.forEach((r) => {
    if (!r || !r.tag) return;
    const o = document.createElement("option");
    o.value = r.tag;
    const mark =
      r.direction === "same" ? " ★ текущая" : r.direction === "older" ? " ↓ откат" : " ↑ новее";
    o.textContent = (r.tag || r.version) + mark + (r.changelog && r.changelog.headline ? " — " + r.changelog.headline : "");
    sel.appendChild(o);
  });
  const prefer =
    releases.find((r) => r.direction === "newer") ||
    releases.find((r) => r.direction === "same") ||
    releases[0];
  if (prefer) {
    sel.value = prefer.tag;
    renderSelectedRelease(prefer);
  }
}

function applyVersionsData(data) {
  if (!data) return;
  versionsCache = data;
  fillVersionsSelect(data);
  // Soft-refresh installed/latest labels without auto-opening the update modal
  if (data.installed && versionCache) {
    const top = (data.releases && data.releases[0]) || null;
    versionCache = {
      ...versionCache,
      installed: data.installed,
      latest: top && top.version ? top.version : versionCache.latest,
      tag: top && top.tag ? top.tag : versionCache.tag,
      update_available: top ? top.direction === "newer" : !!versionCache.update_available,
      error: data.error || versionCache.error || null,
    };
    if (byId("installedVer") && data.installed) byId("installedVer").textContent = "v" + data.installed;
    if (byId("versionsInstalled")) byId("versionsInstalled").textContent = "v" + data.installed;
    if (byId("latestVer") && versionCache.latest) byId("latestVer").textContent = "GitHub: " + versionCache.latest;
  }
}

function openVersionsModal(data) {
  const modal = byId("versionsModal");
  if (!modal) return;
  if (data) applyVersionsData(data);
  else fillVersionsSelect(versionsCache);
  modal.classList.add("show");
}

function closeVersionsModal() {
  const modal = byId("versionsModal");
  if (modal) modal.classList.remove("show");
}

function setVersionsSelectLoading(on) {
  const sel = byId("versionSelect");
  const refresh = byId("btnVersionsRefresh");
  if (sel) sel.disabled = !!on;
  if (refresh) refresh.disabled = !!on;
  if (on && sel) {
    sel.innerHTML = "";
    const o = document.createElement("option");
    o.value = "";
    o.textContent = "Загрузка списка с GitHub…";
    sel.appendChild(o);
  }
}

async function requestVersionsList(andOpen) {
  // XrayUI-style: open overlay, load releases via fetch — never start_apply.
  if (andOpen !== false) openVersionsModal(versionsCache);
  setVersionsSelectLoading(true);
  setVersionsModalStatus("loading", "Загрузка релизов с GitHub…");
  setMsg("Загрузка списка версий с GitHub…", "");
  const installed = installedVersionHint();
  try {
    const list = await fetchGithubJson(SS_GH_RELEASES_API + "?per_page=" + (SS_RELEASES_TO_SHOW + 5));
    if (!Array.isArray(list)) throw new Error("unexpected releases response");
    const data = buildVersionsFromGithubList(list, installed);
    if (!data.releases.length) throw new Error("пустой список релизов");
    applyVersionsData(data);
    setVersionsModalStatus("", "");
    setMsg("Загружено релизов: " + data.releases.length, "ok");
    if (andOpen !== false) openVersionsModal(data);
  } catch (err) {
    // Soft fallback to cached /ext JSON written by CLI/cron — still no apply form
    try {
      const cached = await fetchJson(EXT + "/versions.json");
      if (cached && Array.isArray(cached.releases) && cached.releases.length) {
        applyVersionsData(cached);
        setVersionsModalStatus("warn", "GitHub недоступен из браузера — показан кэш роутера.");
        setMsg("Показан кэш versions.json (GitHub: " + (err && err.message ? err.message : "ошибка") + ")", "warn");
        if (andOpen !== false) openVersionsModal(cached);
        return;
      }
    } catch (_) {}
    const msg = err && err.message ? err.message : String(err);
    applyVersionsData({
      installed: installed,
      repo: SS_GH_REPO,
      checked_at: Math.floor(Date.now() / 1000),
      error: msg,
      releases: (versionsCache && versionsCache.releases) || [],
    });
    setVersionsModalStatus("error", "Не удалось загрузить релизы: " + msg);
    setMsg("Не удалось загрузить список версий: " + msg, "err");
  } finally {
    setVersionsSelectLoading(false);
  }
}

async function checkUpdateFromGithub(opts) {
  const options = opts || {};
  if (!options.quiet) setMsg("Проверка версии на GitHub…", "");
  const installed = installedVersionHint();
  try {
    const latestRel = await fetchGithubJson(SS_GH_LATEST_API);
    const info = buildVersionInfoFromGithubLatest(latestRel, installed);
    // Skip auto-modal inside renderVersion when caller will decide (boot / forced open)
    if (options.skipAutoModal) info._skipAutoModal = true;
    renderVersion(info);
    if (info.update_available) {
      if (!options.quiet) setMsg("Доступно обновление " + info.latest, "ok");
      // Manual check always shows modal; auto path uses shouldAutoShowUpdateModal
      if (options.openModalIfUpdate) openUpdateModal(info, { markAutoShown: true });
      else if (!options.skipAutoModal && shouldAutoShowUpdateModal(info)) {
        openUpdateModal(info, { markAutoShown: true });
      }
    } else {
      if (!options.quiet) setMsg("Установлена актуальная версия " + (info.installed || installed), "ok");
      if (options.openModalAlways) openUpdateModal(info);
    }
    return info;
  } catch (err) {
    const msg = err && err.message ? err.message : String(err);
    try {
      const cached = await fetchJson(EXT + "/version.json");
      if (cached) {
        if (options.skipAutoModal) cached._skipAutoModal = true;
        renderVersion({ ...cached, error: cached.error || msg });
        if (!options.quiet) {
          setMsg("GitHub из браузера недоступен — показан кэш version.json (" + msg + ")", "warn");
        }
        return cached;
      }
    } catch (_) {}
    if (!options.quiet) setMsg("Проверка версии не удалась: " + msg, "err");
    return null;
  }
}

function installSelectedVersion() {
  const rel = selectedRelease || findReleaseByTag(byId("versionSelect") && byId("versionSelect").value);
  if (!rel || !rel.tag) {
    setMsg("Сначала выберите версию", "err");
    return;
  }
  const dir = rel.direction || "same";
  let msg = "Установить " + rel.tag + " с GitHub?";
  if (dir === "older") msg = "Откатиться на " + rel.tag + "? Текущая версия будет заменена.";
  else if (dir === "newer") msg = "Обновить до " + rel.tag + "?";
  else msg = "Переустановить текущую " + rel.tag + "?";
  if (!confirm(msg)) return;
  closeVersionsModal();
  triggerService("installversion", { tag: rel.tag, force: dir === "same" ? "1" : "0" });
}

function maybeAutoOpenUpdateModal(info) {
  if (info && info._skipAutoModal) return;
  if (!shouldAutoShowUpdateModal(info)) return;
  try {
    if (sessionStorage.getItem("ss_update_autoshown_" + updateNoticeTag(info)) === "1") return;
  } catch (_) {}
  openUpdateModal(info, { markAutoShown: true });
}

function renderVersion(info) {
  if (!info) return;
  versionCache = info;
  const installed = info.installed || "—";
  const latest = info.latest || null;
  const upd = !!info.update_available;

  if (byId("installedVer")) {
    byId("installedVer").textContent = installed && installed !== "—" ? "v" + installed : "—";
    byId("installedVer").style.color = upd ? "#fc0" : "#fc0";
  }
  if (byId("latestVer")) {
    byId("latestVer").textContent = latest ? "GitHub: " + latest : "GitHub: —";
  }
  if (byId("titleVer") && installed && installed !== "—") byId("titleVer").textContent = "v" + installed;
  if (byId("footerVer") && installed && installed !== "—") byId("footerVer").textContent = "v" + installed;
  if (byId("versionsInstalled") && installed && installed !== "—") byId("versionsInstalled").textContent = "v" + installed;

  const pill = byId("updatePill");
  const banner = byId("updateBanner");
  const btnUpdate = byId("btnUpdate");
  if (upd) {
    pill.style.display = "inline-block";
    pill.className = labelClass("warn");
    pill.textContent = "есть обновление " + latest;
    banner.classList.add("show");
    byId("bannerLatest").textContent = latest + (info.tag ? " (" + info.tag + ")" : "");
    byId("bannerInstalled").textContent = installed;
    btnUpdate.style.display = "inline-block";
    // Banner always shows when update exists; modal only if not Later/Dismissed
    maybeAutoOpenUpdateModal(info);
  } else {
    pill.style.display = "none";
    banner.classList.remove("show");
    btnUpdate.style.display = "none";
    closeUpdateModal();
  }

  let t = "установлена " + installed;
  if (latest) t += " · GitHub " + latest;
  if (info.error) t += " · ошибка проверки: " + info.error;
  else if (upd) t += " · доступно обновление";
  else if (latest) t += " · актуально";
  if (upd && info.changelog && info.changelog.headline) t += " · " + info.changelog.headline;
  const cls = labelClass(upd ? "warn" : latest ? "on" : "muted");
  const detail = byId("verDetail");
  if (detail) {
    detail.textContent = t;
    detail.className = cls;
  }
  const detailAdv = byId("verDetailAdvanced");
  if (detailAdv) {
    detailAdv.textContent = t;
    detailAdv.className = cls;
  }
}

function enabledSet() {
  const list = outboundsCache.enabled || stateCache?.enabled_outbounds || [];
  return new Set(list.map(String));
}

function configLabel(id) {
  const c = (configsCache || []).find((x) => String(x.id) === String(id));
  if (!c) return "#" + id;
  const name = c.name || c.title || "";
  return name ? "#" + id + " · " + name : "#" + id;
}

function fillOutboundSelects() {
  const ids = (configsCache || []).filter(Boolean).map((c) => c.id);
  const enabled = enabledSet();
  for (const selId of ["defaultOutbound", "presetDefault", "presetAlt", "ruleOutbound"]) {
    const sel = byId(selId);
    if (!sel) continue;
    const prev = sel.value;
    sel.innerHTML = "";
    if (selId === "defaultOutbound" || selId === "ruleOutbound") {
      ["direct", "block"].forEach((t) => {
        const o = document.createElement("option");
        o.value = t;
        o.textContent = t;
        sel.appendChild(o);
      });
    }
    // Prefer enabled VPN outbounds for rule builder; presets still list all ids
    const useIds =
      selId === "ruleOutbound" ? ids.filter((id) => enabled.has(String(id))) : ids;
    const list = useIds.length || selId !== "ruleOutbound" ? useIds : ids;
    list.forEach((id) => {
      const o = document.createElement("option");
      o.value = selId === "presetDefault" || selId === "presetAlt" ? String(id) : "ss-" + id;
      o.textContent =
        selId === "presetDefault" || selId === "presetAlt" ? configLabel(id) : "ss-" + id + " · " + configLabel(id);
      if (selId === "ruleOutbound" && enabled.has(String(id))) o.textContent += " ✓";
      sel.appendChild(o);
    });
    if (prev) sel.value = prev;
  }
  if (outboundsCache.default && byId("defaultOutbound")) {
    byId("defaultOutbound").value = outboundsCache.default;
  }
  // Default rule outbound → current default VPN if enabled
  if (byId("ruleOutbound") && outboundsCache.default && !byId("ruleOutbound").value) {
    byId("ruleOutbound").value = outboundsCache.default;
  }
}

function suggestCatalog(type) {
  const pack = window.SS_ROUTING_SUGGEST || {};
  if (type === "geosite") {
    return (pack.geosite || []).map((x) =>
      typeof x === "string" ? { id: x, label: x } : { id: x.id, label: x.label || x.id }
    );
  }
  if (type === "geoip") {
    return (pack.geoip || []).map((x) =>
      typeof x === "string" ? { id: x, label: x } : { id: x.id, label: x.label || x.id }
    );
  }
  if (type === "domain" || type === "full" || type === "keyword") {
    return (pack.domains || []).map((d) => ({ id: d, label: d }));
  }
  return [];
}

function filterSuggestions(query, items) {
  const q = String(query || "")
    .trim()
    .toLowerCase();
  if (!q) return items.slice(0, 12);
  const starts = [];
  const contains = [];
  items.forEach((it) => {
    const id = String(it.id || "").toLowerCase();
    const label = String(it.label || "").toLowerCase();
    if (id.startsWith(q) || label.startsWith(q)) starts.push(it);
    else if (id.includes(q) || label.includes(q)) contains.push(it);
  });
  return starts.concat(contains).slice(0, 12);
}

let suggestActiveIndex = -1;

function hideRuleSuggest() {
  const box = byId("ruleSuggestBox");
  if (box) box.classList.remove("show");
  suggestActiveIndex = -1;
}

function showRuleSuggest() {
  const type = byId("ruleType") ? byId("ruleType").value : "domain";
  const input = byId("ruleMatcher");
  const box = byId("ruleSuggestBox");
  const hint = byId("ruleSuggestHint");
  if (!input || !box) return;

  const catalog = suggestCatalog(type);
  if (!catalog.length) {
    hideRuleSuggest();
    if (hint) {
      hint.textContent =
        type === "regexp" || type === "ip"
          ? "Для этого типа подсказки не нужны — введите значение вручную."
          : "Список подсказок пуст.";
    }
    return;
  }

  const matches = filterSuggestions(input.value, catalog);
  box.innerHTML = "";
  if (!matches.length) {
    const empty = document.createElement("div");
    empty.className = "ss-suggest-empty";
    empty.textContent = "Нет совпадений в списке — можно ввести своё значение";
    box.appendChild(empty);
    box.classList.add("show");
    if (hint) hint.textContent = "Домен/категория не найдены в подсказках — правило всё равно можно добавить.";
    return;
  }

  matches.forEach((it, idx) => {
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = "ss-suggest-item" + (idx === suggestActiveIndex ? " active" : "");
    btn.setAttribute("role", "option");
    btn.dataset.value = it.id;
    btn.textContent = it.label;
    btn.addEventListener("mousedown", (e) => {
      e.preventDefault();
      input.value = it.id;
      hideRuleSuggest();
      if (hint) {
        hint.textContent = "Выбрано из списка: " + it.id + (it.label !== it.id ? " (" + it.label + ")" : "");
        hint.className = "ss-hint ok";
      }
    });
    box.appendChild(btn);
  });
  box.classList.add("show");
  if (hint) {
    const exact = catalog.some((it) => String(it.id).toLowerCase() === String(input.value).trim().toLowerCase());
    hint.className = "ss-hint" + (exact ? " ok" : "");
    hint.textContent = exact
      ? "Есть в списке подсказок ✓"
      : "Подсказки из списка (домены / geosite / geoip). Выберите пункт или оставьте свой ввод.";
  }
}

function syncRulesJsonFromCache() {
  if (byId("routingJson")) {
    byId("routingJson").value = JSON.stringify(routingCache.rules || [], null, 2);
  }
}

function renderRulesTable() {
  const tbody = byId("rulesTable");
  if (!tbody) return;
  tbody.innerHTML = "";
  const rules = routingCache.rules || [];
  if (!rules.length) {
    const tr = document.createElement("tr");
    tr.innerHTML = '<td colspan="7" style="color:#9ab">Правил пока нет — добавьте выше или примените пресет</td>';
    tbody.appendChild(tr);
    return;
  }
  rules.forEach((r, idx) => {
    const tr = document.createElement("tr");
    tr.innerHTML =
      "<td>" +
      (idx + 1) +
      "</td><td>" +
      (r.name || "—") +
      "</td><td>" +
      (r.type || "—") +
      "</td><td><code>" +
      (r.matcher || r.value || "—") +
      "</code></td><td>" +
      (r.outbound || "—") +
      "</td><td>" +
      (r.priority ?? "—") +
      "</td><td></td>";
    const btn = document.createElement("input");
    btn.type = "button";
    btn.className = btnClass("danger");
    btn.value = "×";
    btn.title = "Удалить";
    btn.addEventListener("click", () => {
      routingCache.rules.splice(idx, 1);
      renderRouting(routingCache);
    });
    tr.lastChild.appendChild(btn);
    tbody.appendChild(tr);
  });
}

function protoSupported(proto) {
  const info = protocolsCache[proto];
  if (!info) {
    // Optimistic defaults until protocols.json loads (all API protocols are handled)
    return PROTO_OPTIONS.includes(proto);
  }
  return !!info.supported;
}

function protoBadge(proto) {
  const info = protocolsCache[proto];
  if (!info) return "";
  if (info.supported) {
    const st = info.status ? String(info.status) : info.runtime || "ok";
    return (
      ' <span class="label label-success" title="' + st + '">' + (info.runtime || "ok") + "</span>"
    );
  }
  return ' <span class="label label-warning" title="' + (info.status || "") + '">n/a</span>';
}

function openConfigEditModal(configId) {
  const select = byId("configSelect");
  if (select && configId != null) {
    select.value = String(configId);
    onConfigChange();
  }
  const c = (configsCache || []).find((x) => x && String(x.id) === String(configId));
  const title = byId("catalogModalTitle");
  const summary = byId("catalogModalSummary");
  if (title) {
    title.textContent = c
      ? "Outbound · " + (c.title || "#" + c.id)
      : "Outbound settings";
  }
  if (summary) {
    summary.textContent = c
      ? "#" + c.id + " · " + (c.protocol || "—") + " · location " + (c.location_id ?? "—")
      : "Смена location / protocol и опции для выбранного конфига.";
  }
  openSsModal("catalogModal");
}

function renderConfigs(configs) {
  configsCache = (configs || []).filter(Boolean);
  const filterEl = byId("catalogFilter");
  const filter = ((filterEl && filterEl.value) || "").toLowerCase();
  const listBody = byId("outboundListBody");
  const legacyTable = byId("configTable");
  const select = byId("configSelect");
  if (legacyTable) legacyTable.innerHTML = "";
  if (select) select.innerHTML = "";
  const en = enabledSet();

  // Keep filter/default row; remove previously rendered proxy rows
  if (listBody) {
    Array.from(listBody.querySelectorAll("tr.ss-proxy-row")).forEach((tr) => tr.remove());
  }

  configsCache.forEach((c) => {
    const hay = [c.id, c.title, c.protocol, c.location_id].join(" ").toLowerCase();
    if (filter && !hay.includes(filter)) return;
    const supported = protoSupported(c.protocol);
    const enabled = en.has(String(c.id));
    const info = protocolsCache[c.protocol] || {};
    const runtime = info.runtime || (String(c.protocol || "").indexOf("hysteria") >= 0 ? "hysteria" : "xray");

    if (listBody) {
      const tr = document.createElement("tr");
      tr.className = "ss-proxy-row";
      const th = document.createElement("th");
      th.innerHTML =
        '<span class="ss-proxy-dot ' +
        (c.is_online ? "on" : enabled ? "err" : "") +
        '" title="' +
        (c.is_online ? "online" : "offline") +
        '"></span>' +
        (c.title || "#" + c.id);
      const td = document.createElement("td");
      const tags = document.createElement("span");
      tags.innerHTML =
        '<span class="ss-proxy-tag proto">' +
        (c.protocol || "—") +
        "</span>" +
        '<span class="ss-proxy-tag runtime">' +
        runtime +
        "</span>" +
        (enabled
          ? '<span class="ss-proxy-tag sec">ss-' + c.id + "</span>"
          : '<span class="ss-proxy-tag off">off</span>');
      td.appendChild(tags);
      const actions = document.createElement("span");
      actions.className = "row-buttons";
      if (supported) {
        const edit = document.createElement("input");
        edit.type = "button";
        edit.className = btnClass("");
        edit.value = "e";
        edit.title = "Редактировать";
        edit.addEventListener("click", () => openConfigEditModal(c.id));
        const tog = document.createElement("input");
        tog.type = "button";
        tog.className = btnClass(enabled ? "secondary" : "");
        tog.value = enabled ? "x" : "+";
        tog.title = enabled ? "Выключить outbound" : "Включить outbound";
        tog.addEventListener("click", () =>
          triggerService(enabled ? "disableoutbound" : "enableoutbound", { config_id: Number(c.id) })
        );
        actions.appendChild(edit);
        actions.appendChild(tog);
      } else {
        const n = document.createElement("span");
        n.className = "ss-meta-inline";
        n.textContent = "в разработке";
        actions.appendChild(n);
      }
      td.appendChild(actions);
      tr.appendChild(th);
      tr.appendChild(td);
      listBody.appendChild(tr);
    }

    if (legacyTable) {
      const tr = document.createElement("tr");
      tr.innerHTML = "<td>" + c.id + "</td><td>" + (c.title || "—") + "</td>";
      legacyTable.appendChild(tr);
    }

    if (select) {
      const opt = document.createElement("option");
      opt.value = String(c.id);
      opt.textContent = "#" + c.id + " " + (c.title || "") + " (" + c.protocol + ")";
      opt.dataset.locationId = String(c.location_id ?? "");
      opt.dataset.protocol = c.protocol || "vless";
      opt.disabled = !supported;
      select.appendChild(opt);
    }
  });
  fillOutboundSelects();
  onConfigChange();
  updateSectionSummaries();
}

function renderLocations(locations) {
  const select = byId("locationSelect");
  select.innerHTML = "";
  let list = [];
  if (Array.isArray(locations)) list = locations;
  else if (locations && Array.isArray(locations.items)) list = locations.items;
  else if (locations && typeof locations === "object") list = Object.values(locations);

  list.filter(Boolean).forEach((loc) => {
    const id = loc.id ?? loc.location_id;
    if (id == null) return;
    const name = loc.name || loc.title || loc.code || String(id);
    const opt = document.createElement("option");
    opt.value = String(id);
    opt.textContent = name + " (" + id + ")";
    select.appendChild(opt);
  });
}

function renderProtocolSelect() {
  const p = byId("protocolSelect");
  p.innerHTML = "";
  PROTO_OPTIONS.forEach((proto) => {
    const opt = document.createElement("option");
    opt.value = proto;
    const ok = protoSupported(proto);
    const info = protocolsCache[proto];
    const note = info && info.status ? " — " + info.status : ok ? "" : " (недоступен)";
    opt.textContent = proto + note;
    opt.disabled = !ok;
    p.appendChild(opt);
  });
}

function renderKeys(keys) {
  const tbody = byId("keysTable");
  tbody.innerHTML = "";
  (keys || []).forEach((k) => {
    const tr = document.createElement("tr");
    const tail = (k.key || "").slice(-8);
    tr.innerHTML = "<td>" + (k.label || "—") + "</td><td>…" + tail + "</td><td></td>";
    const btn = document.createElement("input");
    btn.type = "button";
    btn.className = btnClass("danger");
    btn.value = "Удалить";
    btn.addEventListener("click", () => triggerService("removekey", { api_key: k.key }));
    tr.lastChild.appendChild(btn);
    tbody.appendChild(tr);
  });
}

function renderSubs(subs) {
  const tbody = byId("subsTable");
  tbody.innerHTML = "";
  (subs || []).filter(Boolean).forEach((s) => {
    const tr = document.createElement("tr");
    tr.innerHTML =
      "<td>" +
      (s.id ?? "—") +
      "</td><td>" +
      (s.title || s.name || "—") +
      "</td><td>" +
      (s.status || s.is_active || "—") +
      "</td>";
    tbody.appendChild(tr);
  });
}

function renderRouting(routing) {
  routingCache = routing || { rules: [] };
  if (!Array.isArray(routingCache.rules)) routingCache.rules = [];
  syncRulesJsonFromCache();
  renderRulesTable();
  fillOutboundSelects();
}

function addRoutingRuleFromForm() {
  const type = (byId("ruleType") && byId("ruleType").value) || "domain";
  let matcher = (byId("ruleMatcher") && byId("ruleMatcher").value.trim()) || "";
  const outbound = (byId("ruleOutbound") && byId("ruleOutbound").value) || "direct";
  const name = (byId("ruleName") && byId("ruleName").value.trim()) || "";
  const prioRaw = byId("rulePriority") && byId("rulePriority").value;
  const priority = prioRaw ? Number(prioRaw) : (routingCache.rules || []).length + 1;

  if (!matcher) {
    setMsg("Укажите домен / geosite / geoip matcher", "err");
    return;
  }
  if (type === "domain" || type === "full") {
    matcher = matcher.replace(/^https?:\/\//i, "").replace(/\/.*$/, "").toLowerCase();
  }
  if (type === "ip" && matcher.indexOf("/") >= 0) {
    // treat as cidr
  }
  const ruleType = type === "ip" && matcher.indexOf("/") >= 0 ? "cidr" : type;
  const rule = {
    name: name || matcher,
    type: ruleType,
    matcher,
    outbound,
    priority: Number.isFinite(priority) ? priority : 100,
  };
  routingCache.rules = routingCache.rules || [];
  routingCache.rules.push(rule);
  routingCache.rules.sort((a, b) => (a.priority || 9999) - (b.priority || 9999));
  if (byId("ruleMatcher")) byId("ruleMatcher").value = "";
  if (byId("ruleName")) byId("ruleName").value = "";
  hideRuleSuggest();
  renderRouting(routingCache);
  setMsg("Правило добавлено в список. Нажмите «Сохранить routing + Apply».", "ok");
}

function renderPolicies(policies) {
  policiesCache = policies || { catchall: true, rules: [] };
  byId("policyCatchall").checked = !!policiesCache.catchall;
  const tbody = byId("policiesTable");
  tbody.innerHTML = "";
  (policiesCache.rules || []).forEach((r, idx) => {
    const tr = document.createElement("tr");
    tr.innerHTML =
      "<td>" +
      r.mode +
      "</td><td>" +
      r.mac +
      "</td><td>" +
      (r.name || "—") +
      "</td><td>" +
      (r.ports || "—") +
      "</td><td>" +
      (r.proto || "tcp") +
      "</td><td></td>";
    const btn = document.createElement("input");
    btn.type = "button";
    btn.className = btnClass("danger");
    btn.value = "×";
    btn.addEventListener("click", () => {
      policiesCache.rules.splice(idx, 1);
      renderPolicies(policiesCache);
    });
    tr.lastChild.appendChild(btn);
    tbody.appendChild(tr);
  });
}

function renderClients(clients) {
  clientsCache = clients || [];
  const sel = byId("clientSelect");
  sel.innerHTML = "";
  clientsCache.forEach((c) => {
    const opt = document.createElement("option");
    opt.value = c.mac;
    opt.textContent = (c.name || c.ip || c.mac) + " [" + c.mac + "]" + (c.online ? " ●" : "");
    opt.dataset.name = c.name || "";
    sel.appendChild(opt);
  });
}

function parseXraySettingsFlags(raw) {
  const flags = {
    use_xhttp: false,
    use_grpc: false,
    use_warp: false,
    use_salamander: false,
    disable_reality: false,
  };
  if (!raw) return flags;
  let obj = raw;
  if (typeof raw === "string") {
    try {
      obj = JSON.parse(raw);
    } catch (_) {
      return flags;
    }
  }
  if (!obj || typeof obj !== "object") return flags;
  ["use_xhttp", "use_grpc", "use_warp", "use_salamander", "disable_reality"].forEach((k) => {
    if (obj[k] != null) flags[k] = !!obj[k];
  });
  return flags;
}

function onConfigChange() {
  const sel = byId("configSelect");
  if (!sel || !sel.selectedOptions || !sel.selectedOptions[0]) return;
  const opt = sel.selectedOptions[0];
  if (opt.dataset.locationId && byId("locationSelect")) {
    byId("locationSelect").value = opt.dataset.locationId;
  }
  if (opt.dataset.protocol) {
    const p = byId("protocolSelect");
    if (p && [...p.options].some((o) => o.value === opt.dataset.protocol && !o.disabled)) {
      p.value = opt.dataset.protocol;
    }
  }
  const cfg = (configsCache || []).find((c) => c && String(c.id) === String(opt.value));
  const flags = parseXraySettingsFlags(cfg && cfg.xray_config);
  if (byId("optUseXhttp")) byId("optUseXhttp").checked = flags.use_xhttp;
  if (byId("optUseGrpc")) byId("optUseGrpc").checked = flags.use_grpc;
  if (byId("optUseWarp")) byId("optUseWarp").checked = flags.use_warp;
  if (byId("optUseSalamander")) byId("optUseSalamander").checked = flags.use_salamander;
  if (byId("optDisableReality")) byId("optDisableReality").checked = flags.disable_reality;
  const info = protocolsCache[opt.dataset.protocol];
  const runtime = info
    ? "runtime: " + info.runtime + (info.status ? " · " + info.status : "")
    : "";
  if (byId("protoHint")) {
    byId("protoHint").textContent =
      (runtime ? runtime + ". " : "") +
      "Смена на сайте → «Синхронизировать» (или autosync */15) подтянет connection_url и пересоберёт включённые outbound.";
  }
}

async function refreshAll() {
  try {
    const [state, configs, locations, subs, keys, outbounds, routing, policies, version, versions, protocols, response] =
      await Promise.all([
        fetchJson(EXT + "/state.json").catch(() => null),
        fetchJson(EXT + "/configs.json").catch(() => []),
        fetchJson(EXT + "/locations.json").catch(() => []),
        fetchJson(EXT + "/subscriptions.json").catch(() => []),
        fetchJson(EXT + "/api_keys.json").catch(() => []),
        fetchJson(EXT + "/outbounds.json").catch(() => ({ enabled: [], default: "" })),
        fetchJson(EXT + "/routing.json").catch(() => ({ rules: [] })),
        fetchJson(EXT + "/policies.json").catch(() => ({ catchall: true, rules: [] })),
        fetchJson(EXT + "/version.json").catch(() => null),
        fetchJson(EXT + "/versions.json").catch(() => null),
        fetchJson(EXT + "/protocols.json").catch(() => null),
        fetchJson(EXT + "/stealthsurf-response.json").catch(() => null),
      ]);
    outboundsCache = outbounds || { enabled: [], default: "" };
    if (protocols && typeof protocols === "object") protocolsCache = protocols;
    renderState(state);
    if (version) renderVersion(version);
    else if (state && state.version) renderVersion({ installed: state.version, latest: null });
    if (versions && Array.isArray(versions.releases)) {
      versionsCache = versions;
    }
    const cfgList = Array.isArray(configs) ? configs : configs?.data || [];
    renderProtocolSelect();
    renderConfigs(cfgList);
    renderLocations(locations);
    renderSubs(Array.isArray(subs) ? subs : []);
    renderKeys(Array.isArray(keys) ? keys : []);
    renderRouting(routing);
    renderPolicies(policies);
    updateSectionSummaries();
    if (response && response.message) {
      setMsg(response.message, response.status ? "ok" : "err");
      const data = response.data;
      if (data && data.protocols) {
        protocolsCache = data.protocols;
        renderProtocolSelect();
        renderConfigs(cfgList);
      }
      if (data && (data.installed || data.update_available != null)) {
        renderVersion(data);
      }
      if (/version checked|updated|already up to date|already on version/i.test(response.message)) {
        if (data && data.installed) renderVersion(data);
        fetchJson(EXT + "/version.json")
          .then((v) => {
            renderVersion(v);
            if (v && v.update_available) openUpdateModal(v, { keepSeen: true });
          })
          .catch(() => {});
      }
      if (/versions listed/i.test(response.message)) {
        if (data && Array.isArray(data.releases)) {
          applyVersionsData(data);
          openVersionsModal(data);
        } else {
          fetchJson(EXT + "/versions.json")
            .then((v) => {
              applyVersionsData(v);
              openVersionsModal(v);
            })
            .catch(() => {});
        }
      }
      if (/^updated$/i.test(response.message)) {
        setTimeout(() => location.reload(), 1500);
      }
      // clients → array
      if (Array.isArray(data) && /clients/i.test(response.message)) {
        renderClients(data);
      }
      // diag dump
      if (data && (data.firewall || data.xray || data.protocols) && /diag/i.test(response.message)) {
        byId("diagBox").textContent = JSON.stringify(data, null, 2);
      }
      // connectivity
      if (data && (data.ip != null || data.via != null) && /connectivity/i.test(response.message)) {
        byId("diagBox").textContent =
          "IP: " + (data.ip || "—") + "\nvia: " + (data.via || "—") + "\nok: " + String(!!data.ok);
      }
      // backups list embedded in backup/backuplist responses
      if (data && Array.isArray(data.backups)) {
        renderBackups(data.backups);
        if (data.path) setBackupStatus("Создан: " + data.path, "ok");
      } else if (Array.isArray(data) && /backups/i.test(response.message)) {
        renderBackups(data);
        setBackupStatus("Список обновлён (" + data.length + ")", "ok");
      }
      if (/backup ok/i.test(response.message) && data && data.path) {
        setBackupStatus("Backup готов: " + data.path, "ok");
        loadBackups();
      }
      if (/settings saved|settings$/i.test(response.message) && data && typeof data === "object") {
        fillSettingsForm(data);
        setSettingsStatus("Сохранено");
        if (/settings saved/i.test(response.message)) setMsg("Настройки сохранены", "ok");
      }
      if (/^restored$/i.test(response.message)) {
        setBackupStatus("Восстановлено из " + ((data && data.path) || "архива"), "ok");
        setTimeout(() => refreshAll(), 1200);
      }
      if (data && data.text && /logs|devices/i.test(response.message)) {
        showLogText(data.text, data.kind || byId("logKind").value);
      }
      if (/logs cleared/i.test(response.message)) {
        showLogText("(логи очищены)", byId("logKind").value);
        setTimeout(loadLogPreview, 500);
      }
    }
  } catch (e) {
    setMsg(String(e), "err");
  }
}

function bind() {
  document.querySelectorAll(".ss-tab").forEach((t) =>
    t.addEventListener("click", () => switchTab(t.dataset.tab))
  );

  byId("configSelect").addEventListener("change", onConfigChange);
  byId("catalogFilter").addEventListener("input", () => renderConfigs(configsCache));

  byId("btnSaveKey").addEventListener("click", () =>
    triggerService("setkey", { api_key: byId("apiKey").value.trim() })
  );
  byId("btnAddKey").addEventListener("click", () =>
    triggerService("addkey", {
      api_key: byId("apiKey").value.trim(),
      label: byId("apiKeyLabel").value.trim(),
    })
  );
  byId("btnSync").addEventListener("click", () => triggerService("sync", {}));
  byId("btnStart").addEventListener("click", () => {
    const info = xrayuiInfo(stateCache);
    if (info.running) {
      setMsg(info.message || "Сначала остановите XrayUI", "err");
      renderConflict(stateCache);
      return;
    }
    triggerService("start", {});
  });
  byId("btnStop").addEventListener("click", () => triggerService("stop", {}));
  byId("btnRestart").addEventListener("click", () => {
    const info = xrayuiInfo(stateCache);
    if (info.running) {
      setMsg(info.message || "Сначала остановите XrayUI", "err");
      renderConflict(stateCache);
      return;
    }
    triggerService("restart", {});
  });
  byId("btnRefresh").addEventListener("click", () => refreshAll());
  byId("btnCheckUpdate").addEventListener("click", () => checkUpdateFromGithub({ openModalIfUpdate: true }));
  byId("btnUpdate").addEventListener("click", () => {
    openUpdateModal(versionCache, { keepSeen: true });
  });
  if (byId("btnApplyAll")) {
    byId("btnApplyAll").addEventListener("click", () => {
      // Like XrayUI Apply — rebuild dataplane from current settings
      triggerService("rebuild", {}, { wait: 20 });
    });
  }
  if (byId("btnVersionFooter")) {
    byId("btnVersionFooter").addEventListener("click", (e) => {
      e.preventDefault();
      // XrayUI footer opens the version modal (releases list), not Merlin apply
      openVersionsModal(versionsCache);
      requestVersionsList(false);
    });
  }
  if (byId("btnBannerUpdate")) {
    byId("btnBannerUpdate").addEventListener("click", () => {
      if (!confirm("Установить обновление " + (versionCache.latest || "") + "?")) return;
      triggerService("update", { force: "0" });
    });
  }
  if (byId("btnBannerChangelog")) {
    byId("btnBannerChangelog").addEventListener("click", () => openUpdateModal(versionCache, { keepSeen: true }));
  }
  if (byId("btnModalClose")) {
    byId("btnModalClose").addEventListener("click", () => dismissUpdateNotice(versionCache));
  }
  if (byId("btnModalLater")) {
    byId("btnModalLater").addEventListener("click", () => snoozeUpdateNotice(versionCache));
  }
  if (byId("btnModalUpdate")) {
    byId("btnModalUpdate").addEventListener("click", () => {
      const ver = versionCache.latest || versionCache.tag || "";
      if (!confirm("Обновить StealthSurf до " + ver + " с GitHub?")) return;
      closeUpdateModal();
      triggerService("update", { force: "0" });
    });
  }
  if (byId("updateModal")) {
    byId("updateModal").addEventListener("click", (e) => {
      // Click outside = «позднее», чтобы случайно не скрыть навсегда
      if (e.target === byId("updateModal")) snoozeUpdateNotice(versionCache);
    });
  }
  if (byId("btnCheckUpdate2")) {
    byId("btnCheckUpdate2").addEventListener("click", () => checkUpdateFromGithub({ openModalIfUpdate: true }));
  }
  if (byId("btnForceUpdate")) {
    byId("btnForceUpdate").addEventListener("click", () => {
      if (!confirm("Принудительно скачать и установить latest с GitHub (даже если версия та же)?")) return;
      triggerService("update", { force: "1" });
    });
  }
  const openVersionsUi = () => {
    openVersionsModal(versionsCache);
    // Always refresh from GitHub inside the modal (XrayUI loads on open)
    requestVersionsList(false);
  };
  if (byId("btnVersions")) byId("btnVersions").addEventListener("click", openVersionsUi);
  if (byId("btnVersions2")) byId("btnVersions2").addEventListener("click", openVersionsUi);
  if (byId("btnVersionsClose")) byId("btnVersionsClose").addEventListener("click", () => closeVersionsModal());
  if (byId("btnVersionsRefresh")) {
    byId("btnVersionsRefresh").addEventListener("click", () => requestVersionsList(false));
  }
  if (byId("btnVersionInstall")) {
    byId("btnVersionInstall").addEventListener("click", () => installSelectedVersion());
  }
  if (byId("versionSelect")) {
    byId("versionSelect").addEventListener("change", () => {
      renderSelectedRelease(findReleaseByTag(byId("versionSelect").value));
    });
  }
  if (byId("versionsModal")) {
    byId("versionsModal").addEventListener("click", (e) => {
      if (e.target === byId("versionsModal")) closeVersionsModal();
    });
  }

  byId("btnApplySole").addEventListener("click", () =>
    triggerService("apply", { config_id: Number(byId("configSelect").value), sole: "1" })
  );
  byId("btnUpdateSettings").addEventListener("click", () =>
    triggerService("updatesettings", {
      config_id: Number(byId("configSelect").value),
      settings: {
        location_id: Number(byId("locationSelect").value),
        protocol: byId("protocolSelect").value,
        use_xhttp: !!byId("optUseXhttp").checked,
        use_grpc: !!byId("optUseGrpc").checked,
        use_warp: !!byId("optUseWarp").checked,
        use_salamander: !!byId("optUseSalamander").checked,
        disable_reality: !!byId("optDisableReality").checked,
      },
    })
  );
  byId("btnSetDefault").addEventListener("click", () =>
    triggerService("setdefault", { outbound: byId("defaultOutbound").value })
  );
  byId("btnRebuild").addEventListener("click", () =>
    triggerService("setoutbounds", {
      enabled: outboundsCache.enabled || [],
      default: outboundsCache.default || byId("defaultOutbound").value,
    })
  );

  byId("btnPreset").addEventListener("click", () =>
    triggerService("preset", {
      preset: byId("presetSelect").value,
      default_id: Number(byId("presetDefault").value),
      alt_id: Number(byId("presetAlt").value) || undefined,
    })
  );
  if (byId("btnAddRule")) {
    byId("btnAddRule").addEventListener("click", () => addRoutingRuleFromForm());
  }
  if (byId("ruleType")) {
    byId("ruleType").addEventListener("change", () => {
      hideRuleSuggest();
      if (byId("ruleMatcher")) byId("ruleMatcher").placeholder =
        byId("ruleType").value === "geosite"
          ? "например youtube, category-ru…"
          : byId("ruleType").value === "geoip"
            ? "например private, ru, cn…"
            : "например youtube.com";
      showRuleSuggest();
    });
  }
  if (byId("ruleMatcher")) {
    byId("ruleMatcher").addEventListener("input", () => {
      suggestActiveIndex = -1;
      showRuleSuggest();
    });
    byId("ruleMatcher").addEventListener("focus", () => showRuleSuggest());
    byId("ruleMatcher").addEventListener("blur", () => setTimeout(hideRuleSuggest, 180));
    byId("ruleMatcher").addEventListener("keydown", (e) => {
      const box = byId("ruleSuggestBox");
      if (!box || !box.classList.contains("show")) {
        if (e.key === "Enter") {
          e.preventDefault();
          addRoutingRuleFromForm();
        }
        return;
      }
      const items = Array.from(box.querySelectorAll(".ss-suggest-item"));
      if (e.key === "ArrowDown") {
        e.preventDefault();
        suggestActiveIndex = Math.min(items.length - 1, suggestActiveIndex + 1);
        items.forEach((el, i) => el.classList.toggle("active", i === suggestActiveIndex));
      } else if (e.key === "ArrowUp") {
        e.preventDefault();
        suggestActiveIndex = Math.max(0, suggestActiveIndex - 1);
        items.forEach((el, i) => el.classList.toggle("active", i === suggestActiveIndex));
      } else if (e.key === "Enter") {
        e.preventDefault();
        if (suggestActiveIndex >= 0 && items[suggestActiveIndex]) {
          byId("ruleMatcher").value = items[suggestActiveIndex].dataset.value;
          hideRuleSuggest();
        } else {
          addRoutingRuleFromForm();
        }
      } else if (e.key === "Escape") {
        hideRuleSuggest();
      }
    });
  }
  byId("btnSaveRouting").addEventListener("click", () => {
    let rules;
    try {
      // Prefer live table cache; fall back to textarea if user edited JSON
      if (byId("routingJson") && document.activeElement === byId("routingJson")) {
        rules = JSON.parse(byId("routingJson").value || "[]");
        routingCache.rules = rules;
      } else {
        try {
          const fromJson = JSON.parse(byId("routingJson").value || "[]");
          // Keep textarea in sync if user edited it without table
          if (JSON.stringify(fromJson) !== JSON.stringify(routingCache.rules || [])) {
            routingCache.rules = fromJson;
          }
        } catch (_) {}
        rules = routingCache.rules || [];
        syncRulesJsonFromCache();
      }
    } catch (e) {
      setMsg("Невалидный JSON правил: " + e, "err");
      return;
    }
    if (!Array.isArray(rules)) {
      setMsg("Правила должны быть массивом JSON", "err");
      return;
    }
    triggerService("setrouting", {
      rules,
      default_outbound: byId("defaultOutbound").value,
    });
  });
  byId("btnGeodata").addEventListener("click", () => triggerService("geodata", {}));

  byId("btnLoadClients").addEventListener("click", () => triggerService("clients", {}));
  byId("btnAddPolicy").addEventListener("click", () => {
    const mac = byId("clientSelect").value;
    if (!mac) return;
    const name = byId("clientSelect").selectedOptions[0]?.dataset.name || "";
    policiesCache.rules = policiesCache.rules || [];
    policiesCache.rules.push({
      mode: byId("policyMode").value,
      mac,
      name,
      ports: byId("policyPorts").value.trim() || undefined,
      proto: byId("policyProto").value,
    });
    renderPolicies(policiesCache);
  });
  byId("btnSavePolicies").addEventListener("click", () => {
    policiesCache.catchall = byId("policyCatchall").checked;
    triggerService("setpolicies", policiesCache);
  });

  byId("btnSetMode").addEventListener("click", () =>
    triggerService("setmode", { mode: byId("modeSelect").value })
  );
  byId("btnSetDns").addEventListener("click", () =>
    triggerService("setdnsmode", { dns_mode: byId("dnsModeSelect").value })
  );
  byId("btnInstallXray").addEventListener("click", () => triggerService("installxray", {}));
  byId("btnBackup").addEventListener("click", () => {
    setBackupStatus("Создаю backup…", "");
    triggerService("backup", { note: byId("backupNote").value.trim() || "manual" });
    setTimeout(loadBackups, 9000);
  });
  byId("btnBackupList").addEventListener("click", () => {
    setBackupStatus("Обновляю список…", "");
    triggerService("backuplist", {});
    setTimeout(loadBackups, 9000);
  });

  byId("btnDiag").addEventListener("click", () => triggerService("diag", {}));
  byId("btnTestCfg").addEventListener("click", () => triggerService("testconfig", {}));
  byId("btnConnSocks").addEventListener("click", () => triggerService("connectivity", { via: "socks" }));
  byId("btnConnDirect").addEventListener("click", () =>
    triggerService("connectivity", { via: "direct" })
  );
  byId("btnLogs").addEventListener("click", () => {
    const kind = byId("logKind").value;
    setLogMeta("Загрузка «" + kind + "»…");
    triggerService("logs", { kind: kind, lines: "200" });
    setTimeout(loadLogPreview, 9000);
  });
  byId("logKind").addEventListener("change", () => loadLogPreview());
  byId("btnDevicesSnap").addEventListener("click", () => {
    byId("logKind").value = "devices";
    setLogMeta("Снимок LAN устройств…");
    triggerService("devicesnapshot", {});
    setTimeout(loadLogPreview, 9000);
  });
  byId("btnClearLogs").addEventListener("click", () => {
    if (!confirm("Очистить все логи аддона (activity/errors/devices/addon)?")) return;
    triggerService("clearlogs", { kind: "all" });
  });

  if (byId("btnSettings")) {
    byId("btnSettings").addEventListener("click", () => openSettingsModal());
  }
  if (byId("btnSettingsClose")) {
    byId("btnSettingsClose").addEventListener("click", () => closeSettingsModal());
  }

  // Section manage buttons → XrayUI-style modals (Configuration + Advanced)
  const manageMap = [
    ["btnManageKeys", "keysModal"],
    ["btnManageRouting", "routingModal"],
    ["btnManagePolicies", "policiesModal"],
    ["btnManageGeneral", "generalModal"],
    ["btnManageBackup", "backupModal"],
    ["btnManageDiag", "diagModal"],
  ];
  manageMap.forEach(([btnId, modalId]) => {
    const btn = byId(btnId);
    if (!btn) return;
    btn.addEventListener("click", () => openSsModal(modalId));
  });
  // Close controls for all section modals (including outbound edit)
  Object.values(SS_SECTION_MODALS).forEach((modalId) => {
    if (modalId === "settingsModal" || modalId === "versionsModal") return;
    const closeBtn = byId("btnClose_" + modalId);
    if (closeBtn) closeBtn.addEventListener("click", () => closeSsModal(modalId));
    const modal = byId(modalId);
    if (modal) {
      modal.addEventListener("click", (ev) => {
        if (ev.target === modal) closeSsModal(modalId);
      });
    }
  });
  document.addEventListener("keydown", (ev) => {
    if (ev.key !== "Escape") return;
    Object.values(SS_SECTION_MODALS).forEach((mid) => {
      if (mid === "settingsModal") return;
      if (mid === "versionsModal") return;
      const el = byId(mid);
      if (el && el.classList.contains("show")) closeSsModal(mid);
    });
  });
  if (byId("btnSettingsSave")) {
    byId("btnSettingsSave").addEventListener("click", () => saveSettingsFromModal());
  }
  if (byId("setRebootSchedule")) {
    byId("setRebootSchedule").addEventListener("change", () => syncRebootCronVisibility());
  }
  if (byId("btnSettingsBackup")) {
    byId("btnSettingsBackup").addEventListener("click", () => {
      const note = (byId("setBackupNote") && byId("setBackupNote").value.trim()) || "manual";
      setSettingsStatus("Создаю backup…");
      triggerService("backup", { note: note });
      setTimeout(loadBackups, 9000);
    });
  }
  if (byId("btnSettingsBackupList")) {
    byId("btnSettingsBackupList").addEventListener("click", () => {
      setSettingsStatus("Обновляю список backup…");
      triggerService("backuplist", {});
      setTimeout(() => {
        loadBackups();
        setSettingsStatus("Список backup обновлён");
      }, 9000);
    });
  }
  if (byId("btnSettingsGeodataNow")) {
    byId("btnSettingsGeodataNow").addEventListener("click", () => {
      setSettingsStatus("Обновляю geoip/geosite…");
      triggerService("geodata", {});
    });
  }
  if (byId("settingsModal")) {
    byId("settingsModal").addEventListener("click", (ev) => {
      if (ev.target === byId("settingsModal")) closeSettingsModal();
    });
  }
}

function setSettingsStatus(text) {
  const el = byId("settingsStatus");
  if (el) el.textContent = text || "";
}

function syncRebootCronVisibility() {
  const wrap = byId("setRebootCronWrap");
  const sel = byId("setRebootSchedule");
  if (!wrap || !sel) return;
  wrap.style.display = sel.value === "custom" ? "" : "none";
}

function fillSettingsForm(s) {
  const data = s || {};
  if (byId("setAutoStart")) byId("setAutoStart").checked = !!data.auto_start;
  if (byId("setWatchdog")) byId("setWatchdog").checked = data.watchdog !== false;
  if (byId("setAutoBackup")) byId("setAutoBackup").checked = data.auto_backup !== false;
  if (byId("setStartupDelay")) byId("setStartupDelay").value = data.startup_delay != null ? data.startup_delay : 8;
  if (byId("setBackupKeep")) byId("setBackupKeep").value = data.backup_keep != null ? data.backup_keep : 10;
  if (byId("setRebootSchedule")) byId("setRebootSchedule").value = data.reboot_schedule || "off";
  if (byId("setRebootCron")) byId("setRebootCron").value = data.reboot_cron || "";
  if (byId("setGeodataAuto")) byId("setGeodataAuto").checked = !!data.geodata_auto;
  if (byId("setGeodataSchedule")) byId("setGeodataSchedule").value = data.geodata_schedule || "weekly";
  if (byId("setGeodataBase")) {
    byId("setGeodataBase").value =
      data.geodata_base ||
      "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download";
  }
  syncRebootCronVisibility();
}

function collectSettingsPayload() {
  return {
    auto_start: !!( byId("setAutoStart") && byId("setAutoStart").checked ),
    watchdog: !!( byId("setWatchdog") && byId("setWatchdog").checked ),
    auto_backup: !!( byId("setAutoBackup") && byId("setAutoBackup").checked ),
    startup_delay: Number((byId("setStartupDelay") && byId("setStartupDelay").value) || 8),
    backup_keep: Number((byId("setBackupKeep") && byId("setBackupKeep").value) || 10),
    reboot_schedule: (byId("setRebootSchedule") && byId("setRebootSchedule").value) || "off",
    reboot_cron: (byId("setRebootCron") && byId("setRebootCron").value.trim()) || "",
    geodata_auto: !!( byId("setGeodataAuto") && byId("setGeodataAuto").checked ),
    geodata_schedule: (byId("setGeodataSchedule") && byId("setGeodataSchedule").value) || "weekly",
    geodata_base: (byId("setGeodataBase") && byId("setGeodataBase").value.trim()) || "",
  };
}

async function openSettingsModal() {
  const modal = byId("settingsModal");
  if (!modal) return;
  setSettingsStatus("Загрузка…");
  fillSettingsForm({
    auto_start: true,
    watchdog: true,
    auto_backup: true,
    startup_delay: 8,
    backup_keep: 10,
    reboot_schedule: "off",
    geodata_auto: false,
    geodata_schedule: "weekly",
    geodata_base: "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download",
  });
  modal.classList.add("show");
  try {
    const s = await fetchJson(EXT + "/settings.json");
    if (s && typeof s === "object") {
      fillSettingsForm(s);
      setSettingsStatus("");
    } else {
      setSettingsStatus("Используются значения по умолчанию");
    }
  } catch (_) {
    setSettingsStatus("settings.json пока нет — сохраните, чтобы создать");
  }
}

function closeSettingsModal() {
  const modal = byId("settingsModal");
  if (modal) modal.classList.remove("show");
}

function saveSettingsFromModal() {
  const payload = collectSettingsPayload();
  if (payload.reboot_schedule === "custom") {
    const parts = (payload.reboot_cron || "").trim().split(/\s+/);
    if (parts.length < 5) {
      setSettingsStatus("Для своего cron нужно 5 полей");
      setMsg("Неверный reboot cron: нужно 5 полей", "err");
      return;
    }
  }
  if (payload.geodata_base && !/^https?:\/\//i.test(payload.geodata_base)) {
    setSettingsStatus("URL geoip/geosite должен начинаться с http(s)://");
    setMsg("Неверный адрес geodata", "err");
    return;
  }
  setSettingsStatus("Сохраняю…");
  triggerService("setsettings", payload, { wait: 12 });
}

function setBackupStatus(text, cls) {
  const el = byId("backupStatus");
  if (!el) return;
  el.textContent = text || "";
  el.className = "ss-hint" + (cls === "ok" ? " ok" : cls === "err" ? " err" : "");
  if (cls === "ok") setMsg(text, "ok");
  if (cls === "err") setMsg(text, "err");
}

function setLogMeta(text) {
  const el = byId("logMeta");
  if (el) el.textContent = text || "";
}

function showLogText(text, kind) {
  const box = byId("logBox");
  if (!box) return;
  const body = (text || "").trim() || "(пусто)";
  box.textContent = body;
  const lines = body === "(пусто)" ? 0 : body.split("\n").length;
  setLogMeta(
    "Показано: " +
      (kind || byId("logKind").value) +
      " · строк: " +
      lines +
      " · " +
      new Date().toLocaleTimeString()
  );
}

function renderBackups(list) {
  const tbody = byId("backupsTable");
  if (!tbody) return;
  tbody.innerHTML = "";
  const rows = list || [];
  if (!rows.length) {
    setBackupStatus("Backup пока нет — нажмите «Создать backup».", "");
    return;
  }
  setBackupStatus("Найдено backup: " + rows.length, "");
  rows.forEach((b) => {
    const tr = document.createElement("tr");
    const when = b.created_at
      ? new Date(Number(b.created_at) * 1000).toLocaleString()
      : b.stamp || "—";
    tr.innerHTML =
      "<td style=\"word-break:break-all\">" +
      (b.file || "—") +
      "</td><td>" +
      when +
      "</td><td>" +
      (b.note || "—") +
      "</td><td>" +
      (b.version || "—") +
      "</td><td></td>";
    const btn = document.createElement("input");
    btn.type = "button";
    btn.className = btnClass("secondary");
    btn.value = "Restore";
    btn.addEventListener("click", () => {
      const file = b.file || b.path;
      if (!confirm("Восстановить настройки из\n" + file + "?\n\nТекущий конфиг будет сохранён в auto-backup, VPN остановится."))
        return;
      setBackupStatus("Restore: " + file + "…", "");
      triggerService("restore", { path: file });
    });
    tr.lastChild.appendChild(btn);
    tbody.appendChild(tr);
  });
}

async function loadBackups() {
  try {
    const list = await fetchJson(EXT + "/backups.json").catch(() => []);
    if (Array.isArray(list)) renderBackups(list);
  } catch (_) {}
  try {
    const response = await fetchJson(EXT + "/stealthsurf-response.json");
    if (response && response.data) {
      if (Array.isArray(response.data)) renderBackups(response.data);
      if (response.data.backups) renderBackups(response.data.backups);
      if (response.data.path && /backup/i.test(response.message || "")) {
        setBackupStatus("Последний backup: " + response.data.path, "ok");
      }
    }
  } catch (_) {}
}

async function loadLogPreview() {
  const kind = byId("logKind") ? byId("logKind").value : "activity";
  const map = {
    activity: "/activity.log",
    errors: "/errors.log",
    devices: "/devices.log",
    addon: "/addon.log",
    access: "/xray-access.log",
    "xray-error": "/xray-error.log",
  };
  try {
    const response = await fetchJson(EXT + "/stealthsurf-response.json");
    if (
      response &&
      response.data &&
      response.data.text &&
      /logs|devices/i.test(response.message || "")
    ) {
      showLogText(response.data.text, response.data.kind || kind);
      return;
    }
  } catch (_) {}
  // Never pull full xray access/error into the browser — can be huge on LAN routers
  if (kind === "access" || kind === "xray-error") {
    showLogText(
      "Access-лог по умолчанию выключен (SS_XRAY_ACCESS_LOG=0). Для хвоста нажмите «Логи» — backend отдаёт только tail.",
      kind
    );
    return;
  }
  try {
    const res = await fetch(EXT + (map[kind] || "/activity.log") + "?_=" + Date.now(), {
      cache: "no-store",
    });
    const text = await res.text();
    const lines = text.trim().split("\n");
    showLogText(lines.slice(-200).join("\n") || "(пусто)", kind);
  } catch (e) {
    showLogText(String(e), kind);
  }
}

function ensureMerlinChrome() {
  // Backup if body onload initial() raced or failed — fill TopBanner / left menu
  try {
    const page = (location.pathname || "").replace(/^\//, "") || "user1.asp";
    if (document.form) {
      if (document.form.current_page) document.form.current_page.value = page;
      if (document.form.next_page) document.form.next_page.value = page;
    }
    const banner = document.getElementById("TopBanner");
    const menu = document.getElementById("mainMenu");
    const emptyBanner = !banner || !banner.innerHTML || banner.innerHTML.length < 20;
    const emptyMenu = !menu || !menu.innerHTML || menu.innerHTML.length < 20;
    if ((emptyBanner || emptyMenu) && typeof show_menu === "function") {
      show_menu();
    }
  } catch (e) {
    if (typeof console !== "undefined" && console.warn) console.warn("StealthSurf show_menu:", e);
  }
}

function initHelpHints() {
  // Asuswrt-Merlin style: hover the label → overlib tip (no click), like stock hintstyle.
  let tip = byId("ssHelpTip");
  if (!tip) {
    tip = document.createElement("div");
    tip.id = "ssHelpTip";
    tip.setAttribute("role", "tooltip");
    document.body.appendChild(tip);
  }
  let hideTimer = null;
  let showTimer = null;
  const useOverlib = typeof window.overlib === "function";

  const placeTip = (anchor) => {
    const r = anchor.getBoundingClientRect();
    const pad = 8;
    tip.classList.add("show");
    let left = r.right + 10;
    let top = r.top;
    const tw = tip.offsetWidth || 280;
    const th = tip.offsetHeight || 80;
    if (left + tw > window.innerWidth - pad) left = Math.max(pad, r.left - tw - 10);
    if (top + th > window.innerHeight - pad) top = Math.max(pad, window.innerHeight - th - pad);
    if (top < pad) top = pad;
    tip.style.left = left + "px";
    tip.style.top = top + "px";
  };

  const showFallback = (anchor, text) => {
    clearTimeout(hideTimer);
    tip.textContent = text;
    placeTip(anchor);
  };

  const hideFallback = () => {
    clearTimeout(hideTimer);
    tip.classList.remove("show");
  };

  const hideHint = () => {
    clearTimeout(showTimer);
    showTimer = null;
    if (useOverlib && typeof window.nd === "function") {
      try {
        window.nd();
      } catch (_) {}
    }
    hideFallback();
  };

  const showHint = (anchor, text) => {
    clearTimeout(hideTimer);
    clearTimeout(showTimer);
    // Merlin-like delay before showing
    showTimer = setTimeout(() => {
      if (useOverlib) {
        try {
          // Stock Merlin / XrayUI: hover opens overlib, mouseout closes via nd()
          if (typeof window.WIDTH !== "undefined") {
            window.overlib(text, OFFSETX, 8, RIGHT, DELAY, 0, WIDTH, 380);
          } else {
            window.overlib(text);
          }
          hideFallback();
          return;
        } catch (_) {
          /* fall through to CSS tip */
        }
      }
      showFallback(anchor, text);
    }, 350);
  };

  document.querySelectorAll("[data-ss-hint]").forEach((el) => {
    if (el.dataset.ssHelpBound) return;
    el.dataset.ssHelpBound = "1";
    const text = (el.getAttribute("data-ss-hint") || "").trim();
    if (!text) return;

    // Drop previous "?" click targets — tip opens on hover of the whole item
    Array.from(el.querySelectorAll(".ss-help")).forEach((n) => n.parentNode.removeChild(n));

    el.classList.add("ss-hintstyle");
    el.setAttribute("title", ""); // avoid native browser tooltip doubling
    el.addEventListener("mouseover", (ev) => {
      // Don't retrigger when moving between children
      if (ev.relatedTarget && el.contains(ev.relatedTarget)) return;
      showHint(el, text);
    });
    el.addEventListener("mouseout", (ev) => {
      if (ev.relatedTarget && el.contains(ev.relatedTarget)) return;
      hideHint();
    });
  });

  document.addEventListener(
    "scroll",
    () => {
      hideHint();
    },
    true
  );
}

ensureMerlinChrome();
bind();
initHelpHints();
refreshAll();
loadBackups();
setTimeout(loadLogPreview, 300);
setTimeout(ensureMerlinChrome, 50);
setTimeout(ensureMerlinChrome, 500);
// Auto-notify about a newer GitHub release (browser fetch — no Merlin apply/%).
// Shows modal: Обновить / Обновить позднее / Закрыть уведомление.
setTimeout(async () => {
  try {
    // Live GitHub check in browser (no Merlin apply). Opens modal if newer + not Later/Dismissed.
    let info = await checkUpdateFromGithub({ quiet: true, skipAutoModal: true });
    if (!info) {
      try {
        info = await fetchJson(EXT + "/version.json");
        if (info) {
          info._skipAutoModal = true;
          renderVersion(info);
        }
      } catch (_) {}
    }
    if (info && shouldAutoShowUpdateModal(info)) {
      openUpdateModal(info, { markAutoShown: true });
    }
  } catch (_) {
    /* offline / first install */
  }
}, 900);
