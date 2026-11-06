const EXT = "/ext/stealthsurf";

const $ = (id) => document.getElementById(id);

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

function setMsg(text, kind) {
  const el = $("msg");
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

function buildAmngCustom(payload) {
  // Namespace under .stealthsurf so we do not wipe other Merlin addons' amng_custom keys.
  let base = {};
  try {
    if (typeof custom_settings === "object" && custom_settings) {
      base = JSON.parse(JSON.stringify(custom_settings));
    }
  } catch (_) {
    base = {};
  }
  base.stealthsurf = payload || {};
  let blob = JSON.stringify(base);
  // Merlin amng_custom is size-limited; fall back to namespaced-only payload
  if (blob.length > 3500) {
    blob = JSON.stringify({ stealthsurf: payload || {} });
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
  // Update downloads a release — needs a longer httpd wait / refresh
  let wait = Number(options.wait || 0);
  if (!wait) {
    if (action === "update" || action === "upgrade") wait = 40;
    else if (action === "checkupdate") wait = 15;
    else if (action === "installxray" || action === "sync") wait = 20;
    else if (action === "backup" || action === "restore") wait = 15;
    else if (action === "logs" || action === "devicesnapshot" || action === "clearlogs") wait = 12;
    else wait = 10;
  }

  try {
    sessionStorage.setItem("ss_payload", JSON.stringify(data));
  } catch (_) {}

  const form = document.form || $("ruleForm");
  if (!form) {
    setMsg("Форма действия не найдена", "err");
    return;
  }

  const blob = buildAmngCustom(data);
  if (blob.length > 3500) {
    setMsg(
      "Payload слишком большой (" + blob.length + " байт). Упростите routing/policies или правьте через CLI.",
      "err"
    );
    return;
  }
  $("ss_payload_field").value = blob;

  const page = (location.pathname || "").replace(/^\//, "") || "user1.asp";
  if (form.current_page) form.current_page.value = page;
  if (form.next_page) form.next_page.value = page;
  form.action_script.value = "stealthsurf_" + action;
  form.action_mode.value = "apply";
  form.action_wait.value = String(wait);

  const labels = {
    checkupdate: "Проверка версии на GitHub…",
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
  };
  setMsg(labels[action] || "Выполняется: " + action + "…", "");
  if (typeof showLoading === "function") showLoading();
  form.submit();
  setTimeout(() => refreshAll(), Math.max(3000, wait * 1000 - 1000));
}

function switchTab(name) {
  document.querySelectorAll(".ss-tab").forEach((t) => {
    t.classList.toggle("active", t.dataset.tab === name);
  });
  document.querySelectorAll(".ss-panel[id^='tab-']").forEach((p) => {
    p.classList.toggle("active", p.id === "tab-" + name);
  });
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
  const banner = $("conflictBanner");
  const conflictPill = $("conflictPill");
  const xrayuiPill = $("xrayuiPill");
  const btnStart = $("btnStart");
  const btnRestart = $("btnRestart");

  if (banner) {
    if (info.running) {
      banner.classList.add("show");
      if ($("conflictText") && info.message) $("conflictText").textContent = info.message;
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
  const pill = $("runState");
  pill.textContent = running ? "running" : "stopped";
  pill.className = labelClass(running ? "on" : "off");
  $("activeCfg").textContent = "active: " + (state.active_config_id ?? "—");
  $("activeCfg").className = labelClass("muted");
  $("modePill").textContent = "mode: " + (state.proxy_mode || state.mode || "—");
  $("modePill").className = labelClass("muted");
  $("ports").textContent =
    "socks :" +
    (state.socks_port || "—") +
    " / http :" +
    (state.http_port || "—") +
    " / tp :" +
    (state.tproxy_port || state.redirect_port || "—");
  $("ports").className = labelClass("muted");
  $("defaultPill").textContent = "default: " + (state.default_outbound || "—");
  $("defaultPill").className = labelClass("muted");
  if (state.mode) $("modeSelect").value = state.mode;
  if (state.dns_mode) $("dnsModeSelect").value = state.dns_mode;
  if (state.version) {
    $("installedVer").textContent = "версия: " + state.version;
    if ($("titleVer")) $("titleVer").textContent = "v" + state.version;
  }
  renderConflict(state);
}

function fillModalList(ulId, boxId, items) {
  const ul = $(ulId);
  const box = $(boxId);
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

function changelogKey(info) {
  return "ss_changelog_seen_" + String((info && (info.tag || info.latest)) || "");
}

function openUpdateModal(info, opts) {
  const data = info || versionCache || {};
  const modal = $("updateModal");
  if (!modal) return;
  const options = opts || {};
  const cl = data.changelog || {};
  const latest = data.latest || data.tag || "—";
  const installed = data.installed || "—";

  if ($("modalLatest")) $("modalLatest").textContent = latest;
  if ($("modalSummary")) {
    $("modalSummary").textContent =
      cl.summary ||
      cl.headline ||
      ("Сейчас установлена " + installed + ". На GitHub есть " + latest + ".");
  }
  fillModalList("modalFeatures", "modalFeatBox", cl.features);
  fillModalList("modalFixes", "modalFixBox", cl.fixes);
  fillModalList("modalOther", "modalOtherBox", cl.other);

  const link = $("modalGhLink");
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
  if (!options.keepSeen) {
    try {
      sessionStorage.setItem(changelogKey(data), "1");
    } catch (_) {}
  }
}

function closeUpdateModal() {
  const modal = $("updateModal");
  if (modal) modal.classList.remove("show");
}

function maybeAutoOpenChangelog(info) {
  if (!info || !info.update_available) return;
  if (!info.changelog) return;
  try {
    if (sessionStorage.getItem(changelogKey(info)) === "1") return;
  } catch (_) {}
  openUpdateModal(info);
}

function renderVersion(info) {
  if (!info) return;
  versionCache = info;
  const installed = info.installed || "—";
  const latest = info.latest || null;
  const upd = !!info.update_available;

  $("installedVer").textContent = "версия: " + installed;
  $("installedVer").className = labelClass(upd ? "warn" : "on");
  $("latestVer").textContent = latest ? "GitHub: " + latest : "GitHub: —";
  $("latestVer").className = labelClass(upd ? "warn" : "muted");
  if ($("titleVer") && installed && installed !== "—") $("titleVer").textContent = "v" + installed;

  const pill = $("updatePill");
  const banner = $("updateBanner");
  const btnUpdate = $("btnUpdate");
  if (upd) {
    pill.style.display = "inline-block";
    pill.className = labelClass("warn");
    pill.textContent = "есть обновление " + latest;
    banner.classList.add("show");
    $("bannerLatest").textContent = latest + (info.tag ? " (" + info.tag + ")" : "");
    $("bannerInstalled").textContent = installed;
    btnUpdate.style.display = "inline-block";
    maybeAutoOpenChangelog(info);
  } else {
    pill.style.display = "none";
    banner.classList.remove("show");
    btnUpdate.style.display = "none";
    closeUpdateModal();
  }

  const detail = $("verDetail");
  if (detail) {
    let t = "установлена " + installed;
    if (latest) t += " · GitHub " + latest;
    if (info.error) t += " · ошибка проверки: " + info.error;
    else if (upd) t += " · доступно обновление";
    else if (latest) t += " · актуально";
    if (upd && info.changelog && info.changelog.headline) t += " · " + info.changelog.headline;
    detail.textContent = t;
    detail.className = labelClass(upd ? "warn" : latest ? "on" : "muted");
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
    const sel = $(selId);
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
  if (outboundsCache.default && $("defaultOutbound")) {
    $("defaultOutbound").value = outboundsCache.default;
  }
  // Default rule outbound → current default VPN if enabled
  if ($("ruleOutbound") && outboundsCache.default && !$("ruleOutbound").value) {
    $("ruleOutbound").value = outboundsCache.default;
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
  const box = $("ruleSuggestBox");
  if (box) box.classList.remove("show");
  suggestActiveIndex = -1;
}

function showRuleSuggest() {
  const type = $("ruleType") ? $("ruleType").value : "domain";
  const input = $("ruleMatcher");
  const box = $("ruleSuggestBox");
  const hint = $("ruleSuggestHint");
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
  if ($("routingJson")) {
    $("routingJson").value = JSON.stringify(routingCache.rules || [], null, 2);
  }
}

function renderRulesTable() {
  const tbody = $("rulesTable");
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

function renderConfigs(configs) {
  configsCache = (configs || []).filter(Boolean);
  const filter = ($("catalogFilter").value || "").toLowerCase();
  const tbody = $("configTable");
  const select = $("configSelect");
  tbody.innerHTML = "";
  select.innerHTML = "";
  const en = enabledSet();

  configsCache.forEach((c) => {
    const hay = [c.id, c.title, c.protocol, c.location_id].join(" ").toLowerCase();
    if (filter && !hay.includes(filter)) return;
    const supported = protoSupported(c.protocol);
    const enabled = en.has(String(c.id));
    const tr = document.createElement("tr");
    tr.innerHTML =
      "<td>" +
      c.id +
      "</td><td>" +
      (c.title || "—") +
      "</td><td>" +
      (c.protocol || "—") +
      protoBadge(c.protocol) +
      "</td><td>" +
      (c.location_id ?? "—") +
      "</td><td>" +
      (c.is_online ? "yes" : "no") +
      "</td><td>" +
      (c.expires_at || "—") +
      "</td><td>" +
      (enabled ? '<span class="label label-success">ss-' + c.id + "</span>" : "—") +
      "</td><td></td>";
    const actions = tr.lastChild;
    if (supported) {
      const btn = document.createElement("input");
      btn.type = "button";
      btn.className = btnClass(enabled ? "secondary" : "");
      btn.value = enabled ? "Выкл" : "Вкл outbound";
      btn.addEventListener("click", () =>
        triggerService(enabled ? "disableoutbound" : "enableoutbound", { config_id: Number(c.id) })
      );
      actions.appendChild(btn);
    } else {
      actions.textContent = "в разработке";
    }
    tbody.appendChild(tr);

    const opt = document.createElement("option");
    opt.value = String(c.id);
    opt.textContent = "#" + c.id + " " + (c.title || "") + " (" + c.protocol + ")";
    opt.dataset.locationId = String(c.location_id ?? "");
    opt.dataset.protocol = c.protocol || "vless";
    opt.disabled = !supported;
    select.appendChild(opt);
  });
  fillOutboundSelects();
  onConfigChange();
}

function renderLocations(locations) {
  const select = $("locationSelect");
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
  const p = $("protocolSelect");
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
  const tbody = $("keysTable");
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
  const tbody = $("subsTable");
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
  const type = ($("ruleType") && $("ruleType").value) || "domain";
  let matcher = ($("ruleMatcher") && $("ruleMatcher").value.trim()) || "";
  const outbound = ($("ruleOutbound") && $("ruleOutbound").value) || "direct";
  const name = ($("ruleName") && $("ruleName").value.trim()) || "";
  const prioRaw = $("rulePriority") && $("rulePriority").value;
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
  if ($("ruleMatcher")) $("ruleMatcher").value = "";
  if ($("ruleName")) $("ruleName").value = "";
  hideRuleSuggest();
  renderRouting(routingCache);
  setMsg("Правило добавлено в список. Нажмите «Сохранить routing + Apply».", "ok");
}

function renderPolicies(policies) {
  policiesCache = policies || { catchall: true, rules: [] };
  $("policyCatchall").checked = !!policiesCache.catchall;
  const tbody = $("policiesTable");
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
  const sel = $("clientSelect");
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
  const opt = $("configSelect").selectedOptions[0];
  if (!opt) return;
  if (opt.dataset.locationId) $("locationSelect").value = opt.dataset.locationId;
  if (opt.dataset.protocol) {
    const p = $("protocolSelect");
    if ([...p.options].some((o) => o.value === opt.dataset.protocol && !o.disabled)) {
      p.value = opt.dataset.protocol;
    }
  }
  const cfg = (configsCache || []).find((c) => c && String(c.id) === String(opt.value));
  const flags = parseXraySettingsFlags(cfg && cfg.xray_config);
  $("optUseXhttp").checked = flags.use_xhttp;
  $("optUseGrpc").checked = flags.use_grpc;
  $("optUseWarp").checked = flags.use_warp;
  $("optUseSalamander").checked = flags.use_salamander;
  $("optDisableReality").checked = flags.disable_reality;
  const info = protocolsCache[opt.dataset.protocol];
  const runtime = info
    ? "runtime: " + info.runtime + (info.status ? " · " + info.status : "")
    : "";
  $("protoHint").textContent =
    (runtime ? runtime + ". " : "") +
    "Смена на сайте → «Синхронизировать» (или autosync */15) подтянет connection_url и пересоберёт включённые outbound.";
}

async function refreshAll() {
  try {
    const [state, configs, locations, subs, keys, outbounds, routing, policies, version, protocols, response] =
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
        fetchJson(EXT + "/protocols.json").catch(() => null),
        fetchJson(EXT + "/stealthsurf-response.json").catch(() => null),
      ]);
    outboundsCache = outbounds || { enabled: [], default: "" };
    if (protocols && typeof protocols === "object") protocolsCache = protocols;
    renderState(state);
    if (version) renderVersion(version);
    else if (state && state.version) renderVersion({ installed: state.version, latest: null });
    const cfgList = Array.isArray(configs) ? configs : configs?.data || [];
    renderProtocolSelect();
    renderConfigs(cfgList);
    renderLocations(locations);
    renderSubs(Array.isArray(subs) ? subs : []);
    renderKeys(Array.isArray(keys) ? keys : []);
    renderRouting(routing);
    renderPolicies(policies);
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
      if (/version checked|updated|already up to date/i.test(response.message)) {
        if (data && data.installed) renderVersion(data);
        fetchJson(EXT + "/version.json")
          .then((v) => {
            renderVersion(v);
            if (v && v.update_available) openUpdateModal(v, { keepSeen: true });
          })
          .catch(() => {});
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
        $("diagBox").textContent = JSON.stringify(data, null, 2);
      }
      // connectivity
      if (data && (data.ip != null || data.via != null) && /connectivity/i.test(response.message)) {
        $("diagBox").textContent =
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
      if (/^restored$/i.test(response.message)) {
        setBackupStatus("Восстановлено из " + ((data && data.path) || "архива"), "ok");
        setTimeout(() => refreshAll(), 1200);
      }
      if (data && data.text && /logs|devices/i.test(response.message)) {
        showLogText(data.text, data.kind || $("logKind").value);
      }
      if (/logs cleared/i.test(response.message)) {
        showLogText("(логи очищены)", $("logKind").value);
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

  $("configSelect").addEventListener("change", onConfigChange);
  $("catalogFilter").addEventListener("input", () => renderConfigs(configsCache));

  $("btnSaveKey").addEventListener("click", () =>
    triggerService("setkey", { api_key: $("apiKey").value.trim() })
  );
  $("btnAddKey").addEventListener("click", () =>
    triggerService("addkey", {
      api_key: $("apiKey").value.trim(),
      label: $("apiKeyLabel").value.trim(),
    })
  );
  $("btnSync").addEventListener("click", () => triggerService("sync", {}));
  $("btnStart").addEventListener("click", () => {
    const info = xrayuiInfo(stateCache);
    if (info.running) {
      setMsg(info.message || "Сначала остановите XrayUI", "err");
      renderConflict(stateCache);
      return;
    }
    triggerService("start", {});
  });
  $("btnStop").addEventListener("click", () => triggerService("stop", {}));
  $("btnRestart").addEventListener("click", () => {
    const info = xrayuiInfo(stateCache);
    if (info.running) {
      setMsg(info.message || "Сначала остановите XrayUI", "err");
      renderConflict(stateCache);
      return;
    }
    triggerService("restart", {});
  });
  $("btnRefresh").addEventListener("click", () => refreshAll());
  $("btnCheckUpdate").addEventListener("click", () => triggerService("checkupdate", {}));
  $("btnUpdate").addEventListener("click", () => {
    openUpdateModal(versionCache, { keepSeen: true });
  });
  if ($("btnBannerUpdate")) {
    $("btnBannerUpdate").addEventListener("click", () => {
      if (!confirm("Установить обновление " + (versionCache.latest || "") + "?")) return;
      triggerService("update", { force: "0" });
    });
  }
  if ($("btnBannerChangelog")) {
    $("btnBannerChangelog").addEventListener("click", () => openUpdateModal(versionCache, { keepSeen: true }));
  }
  if ($("btnModalClose")) $("btnModalClose").addEventListener("click", () => closeUpdateModal());
  if ($("btnModalLater")) $("btnModalLater").addEventListener("click", () => closeUpdateModal());
  if ($("btnModalUpdate")) {
    $("btnModalUpdate").addEventListener("click", () => {
      if (!confirm("Установить обновление " + (versionCache.latest || "") + " с GitHub?")) return;
      closeUpdateModal();
      triggerService("update", { force: "0" });
    });
  }
  if ($("updateModal")) {
    $("updateModal").addEventListener("click", (e) => {
      if (e.target === $("updateModal")) closeUpdateModal();
    });
  }
  if ($("btnCheckUpdate2")) {
    $("btnCheckUpdate2").addEventListener("click", () => triggerService("checkupdate", {}));
  }
  if ($("btnForceUpdate")) {
    $("btnForceUpdate").addEventListener("click", () => {
      if (!confirm("Принудительно скачать и установить latest с GitHub (даже если версия та же)?")) return;
      triggerService("update", { force: "1" });
    });
  }

  $("btnApplySole").addEventListener("click", () =>
    triggerService("apply", { config_id: Number($("configSelect").value), sole: "1" })
  );
  $("btnUpdateSettings").addEventListener("click", () =>
    triggerService("updatesettings", {
      config_id: Number($("configSelect").value),
      settings: {
        location_id: Number($("locationSelect").value),
        protocol: $("protocolSelect").value,
        use_xhttp: !!$("optUseXhttp").checked,
        use_grpc: !!$("optUseGrpc").checked,
        use_warp: !!$("optUseWarp").checked,
        use_salamander: !!$("optUseSalamander").checked,
        disable_reality: !!$("optDisableReality").checked,
      },
    })
  );
  $("btnSetDefault").addEventListener("click", () =>
    triggerService("setdefault", { outbound: $("defaultOutbound").value })
  );
  $("btnRebuild").addEventListener("click", () =>
    triggerService("setoutbounds", {
      enabled: outboundsCache.enabled || [],
      default: outboundsCache.default || $("defaultOutbound").value,
    })
  );

  $("btnPreset").addEventListener("click", () =>
    triggerService("preset", {
      preset: $("presetSelect").value,
      default_id: Number($("presetDefault").value),
      alt_id: Number($("presetAlt").value) || undefined,
    })
  );
  if ($("btnAddRule")) {
    $("btnAddRule").addEventListener("click", () => addRoutingRuleFromForm());
  }
  if ($("ruleType")) {
    $("ruleType").addEventListener("change", () => {
      hideRuleSuggest();
      if ($("ruleMatcher")) $("ruleMatcher").placeholder =
        $("ruleType").value === "geosite"
          ? "например youtube, category-ru…"
          : $("ruleType").value === "geoip"
            ? "например private, ru, cn…"
            : "например youtube.com";
      showRuleSuggest();
    });
  }
  if ($("ruleMatcher")) {
    $("ruleMatcher").addEventListener("input", () => {
      suggestActiveIndex = -1;
      showRuleSuggest();
    });
    $("ruleMatcher").addEventListener("focus", () => showRuleSuggest());
    $("ruleMatcher").addEventListener("blur", () => setTimeout(hideRuleSuggest, 180));
    $("ruleMatcher").addEventListener("keydown", (e) => {
      const box = $("ruleSuggestBox");
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
          $("ruleMatcher").value = items[suggestActiveIndex].dataset.value;
          hideRuleSuggest();
        } else {
          addRoutingRuleFromForm();
        }
      } else if (e.key === "Escape") {
        hideRuleSuggest();
      }
    });
  }
  $("btnSaveRouting").addEventListener("click", () => {
    let rules;
    try {
      // Prefer live table cache; fall back to textarea if user edited JSON
      if ($("routingJson") && document.activeElement === $("routingJson")) {
        rules = JSON.parse($("routingJson").value || "[]");
        routingCache.rules = rules;
      } else {
        try {
          const fromJson = JSON.parse($("routingJson").value || "[]");
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
      default_outbound: $("defaultOutbound").value,
    });
  });
  $("btnGeodata").addEventListener("click", () => triggerService("geodata", {}));

  $("btnLoadClients").addEventListener("click", () => triggerService("clients", {}));
  $("btnAddPolicy").addEventListener("click", () => {
    const mac = $("clientSelect").value;
    if (!mac) return;
    const name = $("clientSelect").selectedOptions[0]?.dataset.name || "";
    policiesCache.rules = policiesCache.rules || [];
    policiesCache.rules.push({
      mode: $("policyMode").value,
      mac,
      name,
      ports: $("policyPorts").value.trim() || undefined,
      proto: $("policyProto").value,
    });
    renderPolicies(policiesCache);
  });
  $("btnSavePolicies").addEventListener("click", () => {
    policiesCache.catchall = $("policyCatchall").checked;
    triggerService("setpolicies", policiesCache);
  });

  $("btnSetMode").addEventListener("click", () =>
    triggerService("setmode", { mode: $("modeSelect").value })
  );
  $("btnSetDns").addEventListener("click", () =>
    triggerService("setdnsmode", { dns_mode: $("dnsModeSelect").value })
  );
  $("btnInstallXray").addEventListener("click", () => triggerService("installxray", {}));
  $("btnBackup").addEventListener("click", () => {
    setBackupStatus("Создаю backup…", "");
    triggerService("backup", { note: $("backupNote").value.trim() || "manual" });
    setTimeout(loadBackups, 9000);
  });
  $("btnBackupList").addEventListener("click", () => {
    setBackupStatus("Обновляю список…", "");
    triggerService("backuplist", {});
    setTimeout(loadBackups, 9000);
  });

  $("btnDiag").addEventListener("click", () => triggerService("diag", {}));
  $("btnTestCfg").addEventListener("click", () => triggerService("testconfig", {}));
  $("btnConnSocks").addEventListener("click", () => triggerService("connectivity", { via: "socks" }));
  $("btnConnDirect").addEventListener("click", () =>
    triggerService("connectivity", { via: "direct" })
  );
  $("btnLogs").addEventListener("click", () => {
    const kind = $("logKind").value;
    setLogMeta("Загрузка «" + kind + "»…");
    triggerService("logs", { kind: kind, lines: "200" });
    setTimeout(loadLogPreview, 9000);
  });
  $("logKind").addEventListener("change", () => loadLogPreview());
  $("btnDevicesSnap").addEventListener("click", () => {
    $("logKind").value = "devices";
    setLogMeta("Снимок LAN устройств…");
    triggerService("devicesnapshot", {});
    setTimeout(loadLogPreview, 9000);
  });
  $("btnClearLogs").addEventListener("click", () => {
    if (!confirm("Очистить все логи аддона (activity/errors/devices/addon)?")) return;
    triggerService("clearlogs", { kind: "all" });
  });
}

function setBackupStatus(text, cls) {
  const el = $("backupStatus");
  if (!el) return;
  el.textContent = text || "";
  el.className = "ss-hint" + (cls === "ok" ? " ok" : cls === "err" ? " err" : "");
  if (cls === "ok") setMsg(text, "ok");
  if (cls === "err") setMsg(text, "err");
}

function setLogMeta(text) {
  const el = $("logMeta");
  if (el) el.textContent = text || "";
}

function showLogText(text, kind) {
  const box = $("logBox");
  if (!box) return;
  const body = (text || "").trim() || "(пусто)";
  box.textContent = body;
  const lines = body === "(пусто)" ? 0 : body.split("\n").length;
  setLogMeta(
    "Показано: " +
      (kind || $("logKind").value) +
      " · строк: " +
      lines +
      " · " +
      new Date().toLocaleTimeString()
  );
}

function renderBackups(list) {
  const tbody = $("backupsTable");
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
  const kind = $("logKind") ? $("logKind").value : "activity";
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

ensureMerlinChrome();
bind();
refreshAll();
loadBackups();
setTimeout(loadLogPreview, 300);
setTimeout(ensureMerlinChrome, 50);
setTimeout(ensureMerlinChrome, 500);
// Passive version display only — do NOT auto form-submit checkupdate on page open.
// Auto submit previously hit Merlin start_apply on every visit; cron still runs
// `stealthsurf check-update` every 12h. User can press «Проверить версию».
setTimeout(async () => {
  try {
    const v = await fetchJson(EXT + "/version.json");
    renderVersion(v);
  } catch (_) {
    /* offline / first install */
  }
}, 800);
