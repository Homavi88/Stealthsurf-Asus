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
  el.className = kind || "";
}

async function fetchJson(url) {
  const res = await fetch(url + (url.includes("?") ? "&" : "?") + "_=" + Date.now(), {
    cache: "no-store",
  });
  if (!res.ok) throw new Error(url + " HTTP " + res.status);
  return res.json();
}

function triggerService(action, payload, opts) {
  const data = payload || {};
  const options = opts || {};
  // Update downloads a release — needs a longer httpd wait / refresh
  let wait = Number(options.wait || 0);
  if (!wait) {
    if (action === "update" || action === "upgrade") wait = 40;
    else if (action === "checkupdate") wait = 15;
    else if (action === "installxray" || action === "sync") wait = 20;
    else wait = 10;
  }

  try {
    sessionStorage.setItem("ss_payload", JSON.stringify(data));
  } catch (_) {}

  const form = $("hidden_action_form");
  if (!form) {
    setMsg("Форма действия не найдена", "err");
    return;
  }

  const blob = JSON.stringify(data);
  $("ss_payload_field").value = blob.slice(0, 2048);

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
  };
  setMsg(labels[action] || "Выполняется: " + action + "…", "");
  if (typeof showLoading === "function") showLoading();
  form.submit();
  setTimeout(() => refreshAll(), Math.max(3000, wait * 1000 - 1000));
}

function switchTab(name) {
  document.querySelectorAll(".tab").forEach((t) => {
    t.classList.toggle("active", t.dataset.tab === name);
  });
  document.querySelectorAll(".panel[id^='tab-']").forEach((p) => {
    p.classList.toggle("active", p.id === "tab-" + name);
  });
}

function renderState(state) {
  if (!state) return;
  stateCache = state;
  const running = !!state.running;
  const pill = $("runState");
  pill.textContent = running ? "running" : "stopped";
  pill.className = "pill " + (running ? "on" : "off");
  $("activeCfg").textContent = "active: " + (state.active_config_id ?? "—");
  $("modePill").textContent = "mode: " + (state.proxy_mode || state.mode || "—");
  $("ports").textContent =
    "socks :" +
    (state.socks_port || "—") +
    " / http :" +
    (state.http_port || "—") +
    " / tp :" +
    (state.tproxy_port || state.redirect_port || "—");
  $("defaultPill").textContent = "default: " + (state.default_outbound || "—");
  if (state.mode) $("modeSelect").value = state.mode;
  if (state.dns_mode) $("dnsModeSelect").value = state.dns_mode;
  if (state.version) $("installedVer").textContent = "версия: " + state.version;
}

function renderVersion(info) {
  if (!info) return;
  versionCache = info;
  const installed = info.installed || "—";
  const latest = info.latest || null;
  const upd = !!info.update_available;

  $("installedVer").textContent = "версия: " + installed;
  $("installedVer").className = "pill " + (upd ? "warn" : "on");
  $("latestVer").textContent = latest ? "GitHub: " + latest : "GitHub: —";
  $("latestVer").className = "pill" + (upd ? " update" : "");

  const pill = $("updatePill");
  const banner = $("updateBanner");
  const btnUpdate = $("btnUpdate");
  if (upd) {
    pill.style.display = "inline-block";
    pill.className = "pill update";
    pill.textContent = "есть обновление " + latest;
    banner.classList.add("show");
    $("bannerLatest").textContent = latest + (info.tag ? " (" + info.tag + ")" : "");
    $("bannerInstalled").textContent = installed;
    btnUpdate.style.display = "inline-block";
  } else {
    pill.style.display = "none";
    banner.classList.remove("show");
    btnUpdate.style.display = "none";
  }

  const detail = $("verDetail");
  if (detail) {
    let t = "установлена " + installed;
    if (latest) t += " · GitHub " + latest;
    if (info.error) t += " · ошибка проверки: " + info.error;
    else if (upd) t += " · доступно обновление";
    else if (latest) t += " · актуально";
    detail.textContent = t;
    detail.className = "pill " + (upd ? "update" : latest ? "on" : "");
  }
}

function enabledSet() {
  const list = outboundsCache.enabled || stateCache?.enabled_outbounds || [];
  return new Set(list.map(String));
}

function fillOutboundSelects() {
  const ids = (configsCache || []).filter(Boolean).map((c) => c.id);
  for (const selId of ["defaultOutbound", "presetDefault", "presetAlt"]) {
    const sel = $(selId);
    const prev = sel.value;
    sel.innerHTML = "";
    if (selId === "defaultOutbound") {
      ["direct", "block"].forEach((t) => {
        const o = document.createElement("option");
        o.value = t;
        o.textContent = t;
        sel.appendChild(o);
      });
    }
    ids.forEach((id) => {
      const o = document.createElement("option");
      o.value = selId === "defaultOutbound" ? "ss-" + id : String(id);
      o.textContent = "#" + id;
      sel.appendChild(o);
    });
    if (prev) sel.value = prev;
  }
  if (outboundsCache.default) $("defaultOutbound").value = outboundsCache.default;
}

function protoSupported(proto) {
  const info = protocolsCache[proto];
  if (!info) return proto.startsWith("vless") || proto === "trojan" || proto.includes("shadowsocks");
  return !!info.supported;
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
      (supported ? "" : ' <span class="pill warn">n/a</span>') +
      "</td><td>" +
      (c.location_id ?? "—") +
      "</td><td>" +
      (c.is_online ? "yes" : "no") +
      "</td><td>" +
      (c.expires_at || "—") +
      "</td><td>" +
      (enabled ? '<span class="pill on">ss-' + c.id + "</span>" : "—") +
      "</td><td></td>";
    const actions = tr.lastChild;
    if (supported) {
      const btn = document.createElement("button");
      btn.type = "button";
      btn.className = "small " + (enabled ? "secondary" : "");
      btn.textContent = enabled ? "Выкл" : "Вкл outbound";
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
    opt.textContent = ok ? proto : proto + " (в разработке)";
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
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = "small danger";
    btn.textContent = "Удалить";
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
  $("routingJson").value = JSON.stringify(routingCache.rules || [], null, 2);
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
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = "small danger";
    btn.textContent = "×";
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
  const info = protocolsCache[opt.dataset.protocol];
  $("protoHint").textContent = info
    ? "runtime: " + info.runtime + (info.status ? " · " + info.status : "")
    : "";
}

async function refreshAll() {
  try {
    const [state, configs, locations, subs, keys, outbounds, routing, policies, version, response] =
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
        fetchJson(EXT + "/stealthsurf-response.json").catch(() => null),
      ]);
    outboundsCache = outbounds || { enabled: [], default: "" };
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
      if (response.data && response.data.protocols) {
        protocolsCache = response.data.protocols;
        renderProtocolSelect();
        renderConfigs(cfgList);
      }
      if (response.data && (response.data.installed || response.data.update_available != null)) {
        renderVersion(response.data);
      }
      if (response.message && /version checked|update finished|updated/i.test(response.message)) {
        // Prefer version payload from the action response
        if (response.data && response.data.installed) renderVersion(response.data);
        fetchJson(EXT + "/version.json")
          .then((v) => renderVersion(v))
          .catch(() => {});
      }
    }
  } catch (e) {
    setMsg(String(e), "err");
  }
}

function bind() {
  document.querySelectorAll(".tab").forEach((t) =>
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
  $("btnStart").addEventListener("click", () => triggerService("start", {}));
  $("btnStop").addEventListener("click", () => triggerService("stop", {}));
  $("btnRestart").addEventListener("click", () => triggerService("restart", {}));
  $("btnRefresh").addEventListener("click", () => refreshAll());
  $("btnCheckUpdate").addEventListener("click", () => triggerService("checkupdate", {}));
  $("btnUpdate").addEventListener("click", () => {
    if (!confirm("Установить новую версию с GitHub Releases?")) return;
    triggerService("update", { force: "0" });
  });
  if ($("btnBannerUpdate")) {
    $("btnBannerUpdate").addEventListener("click", () => {
      if (!confirm("Установить обновление " + (versionCache.latest || "") + "?")) return;
      triggerService("update", { force: "0" });
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
  $("btnSaveRouting").addEventListener("click", () => {
    let rules;
    try {
      rules = JSON.parse($("routingJson").value || "[]");
    } catch (e) {
      setMsg("Невалидный JSON правил: " + e, "err");
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
  $("btnBackup").addEventListener("click", () =>
    triggerService("backup", { note: $("backupNote").value.trim() || "manual" })
  );
  $("btnBackupList").addEventListener("click", () => {
    triggerService("backuplist", {});
    setTimeout(loadBackups, 8500);
  });

  $("btnDiag").addEventListener("click", () => triggerService("diag", {}));
  $("btnTestCfg").addEventListener("click", () => triggerService("testconfig", {}));
  $("btnConnSocks").addEventListener("click", () => triggerService("connectivity", { via: "socks" }));
  $("btnConnDirect").addEventListener("click", () =>
    triggerService("connectivity", { via: "direct" })
  );
  $("btnLogs").addEventListener("click", () => {
    triggerService("logs", { kind: $("logKind").value, lines: "200" });
    setTimeout(loadLogPreview, 8500);
  });
  $("btnDevicesSnap").addEventListener("click", () => {
    triggerService("devicesnapshot", {});
    setTimeout(loadLogPreview, 8500);
  });
  $("btnClearLogs").addEventListener("click", () =>
    triggerService("clearlogs", { kind: "all" })
  );
}

function renderBackups(list) {
  const tbody = $("backupsTable");
  if (!tbody) return;
  tbody.innerHTML = "";
  (list || []).forEach((b) => {
    const tr = document.createElement("tr");
    const when = b.created_at
      ? new Date(Number(b.created_at) * 1000).toLocaleString()
      : b.stamp || "—";
    tr.innerHTML =
      "<td>" +
      (b.file || "—") +
      "</td><td>" +
      when +
      "</td><td>" +
      (b.note || "—") +
      "</td><td></td>";
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = "small secondary";
    btn.textContent = "Restore";
    btn.addEventListener("click", () =>
      triggerService("restore", { path: b.file || b.path })
    );
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
      if (response.data.path) setMsg("Backup: " + response.data.path, "ok");
    }
  } catch (_) {}
}

async function loadLogPreview() {
  const kind = $("logKind").value;
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
    if (response && response.data && response.data.text) {
      $("diagBox").textContent = response.data.text;
      return;
    }
  } catch (_) {}
  try {
    const res = await fetch(EXT + (map[kind] || "/activity.log") + "?_=" + Date.now(), {
      cache: "no-store",
    });
    const text = await res.text();
    const lines = text.trim().split("\n");
    $("diagBox").textContent = lines.slice(-200).join("\n") || "(пусто)";
  } catch (e) {
    $("diagBox").textContent = String(e);
  }
}

bind();
refreshAll();
loadBackups();
setTimeout(loadLogPreview, 300);
// Soft re-check: only if version.json is older than 6h (avoids form submit every open)
setTimeout(async () => {
  try {
    const v = await fetchJson(EXT + "/version.json");
    renderVersion(v);
    const age = Date.now() / 1000 - Number(v.checked_at || 0);
    if (!v.checked_at || age > 6 * 3600) {
      triggerService("checkupdate", {});
    }
  } catch (_) {
    /* offline / first install — user can press «Проверить версию» */
  }
}, 800);
