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

function triggerService(action, payload) {
  const data = payload || {};
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
  // Best-effort: also drop payload for service-event hook
  try {
    // Some firmwares ignore this; amng_custom is the primary path
  } catch (_) {}

  form.action_script.value = "stealthsurf_" + action;
  form.action_mode.value = "apply";
  form.action_wait.value = "10";

  setMsg("Выполняется: " + action + "…", "");
  if (typeof showLoading === "function") showLoading();
  form.submit();
  setTimeout(() => refreshAll(), 9000);
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
    const [state, configs, locations, subs, keys, outbounds, routing, policies, response] =
      await Promise.all([
        fetchJson(EXT + "/state.json").catch(() => null),
        fetchJson(EXT + "/configs.json").catch(() => []),
        fetchJson(EXT + "/locations.json").catch(() => []),
        fetchJson(EXT + "/subscriptions.json").catch(() => []),
        fetchJson(EXT + "/api_keys.json").catch(() => []),
        fetchJson(EXT + "/outbounds.json").catch(() => ({ enabled: [], default: "" })),
        fetchJson(EXT + "/routing.json").catch(() => ({ rules: [] })),
        fetchJson(EXT + "/policies.json").catch(() => ({ catchall: true, rules: [] })),
        fetchJson(EXT + "/stealthsurf-response.json").catch(() => null),
      ]);
    outboundsCache = outbounds || { enabled: [], default: "" };
    renderState(state);
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
  $("btnBackup").addEventListener("click", () => triggerService("backup", {}));
  $("btnUpdate").addEventListener("click", () => triggerService("update", {}));

  $("btnDiag").addEventListener("click", () => triggerService("diag", {}));
  $("btnTestCfg").addEventListener("click", () => triggerService("testconfig", {}));
  $("btnConnSocks").addEventListener("click", () => triggerService("connectivity", { via: "socks" }));
  $("btnConnDirect").addEventListener("click", () =>
    triggerService("connectivity", { via: "direct" })
  );
  $("btnLogs").addEventListener("click", () =>
    triggerService("logs", { kind: $("logKind").value, lines: "150" })
  );

  // After diag/logs/connectivity, show response data
  const origRefresh = refreshAll;
  window.__ssShowResponseData = async () => {
    try {
      const response = await fetchJson(EXT + "/stealthsurf-response.json");
      if (response && response.data) {
        if (response.data.protocols) protocolsCache = response.data.protocols;
        if (response.data.text) $("diagBox").textContent = response.data.text;
        else if (response.data.ip) $("diagBox").textContent = JSON.stringify(response.data, null, 2);
        else if (response.data.version || response.data.firewall)
          $("diagBox").textContent = JSON.stringify(response.data, null, 2);
        else if (Array.isArray(response.data) || response.data.mac)
          renderClients(Array.isArray(response.data) ? response.data : []);
      }
    } catch (_) {}
  };
}

bind();
refreshAll();
