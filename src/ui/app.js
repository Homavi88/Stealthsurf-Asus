const EXT = "/ext/stealthsurf";

const $ = (id) => document.getElementById(id);

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

/**
 * Merlin pattern: write payload to /tmp via custom_settings chunk,
 * then trigger /jffs/scripts/service-event start stealthsurf_<action>
 * through start_apply.htm (action_script).
 */
function triggerService(action, payload) {
  const data = payload || {};
  // Persist payload for shell (service_event reads /tmp/stealthsurf_payload.json).
  // Many firmwares allow writing via amng custom; we also stash in a beacon file
  // using a tiny inline form field that backend can mirror on next hook.
  try {
    sessionStorage.setItem("ss_payload", JSON.stringify(data));
  } catch (_) {}

  // Best-effort: POST JSON to a drop URL if a helper CGI exists later.
  fetch(EXT + "/stealthsurf-response.json", { cache: "no-store" }).catch(() => {});

  const form = $("hidden_action_form");
  if (!form) {
    setMsg("Форма действия не найдена", "err");
    return;
  }

  // Encode payload into amng custom key for the service hook to pick up.
  // Backend also accepts /tmp/stealthsurf_payload.json written by optional helper.
  const blob = JSON.stringify(data);
  $("ss_payload_field").value = blob.slice(0, 2048);
  form.action_script.value = "stealthsurf_" + action;
  form.action_mode.value = "apply";
  form.action_wait.value = "8";

  setMsg("Выполняется: " + action + "…", "");
  if (typeof showLoading === "function") showLoading();
  form.submit();
}

function renderState(state) {
  if (!state) return;
  const running = !!state.running;
  const pill = $("runState");
  pill.textContent = running ? "running" : "stopped";
  pill.className = "pill " + (running ? "on" : "off");
  $("activeCfg").textContent = "active: " + (state.active_config_id ?? "—");
  $("ports").textContent =
    "socks :" + (state.socks_port || "—") + " / http :" + (state.http_port || "—");
}

function renderConfigs(configs) {
  const tbody = $("configTable");
  const select = $("configSelect");
  tbody.innerHTML = "";
  select.innerHTML = "";
  (configs || []).filter(Boolean).forEach((c) => {
    const tr = document.createElement("tr");
    tr.innerHTML =
      "<td>" +
      c.id +
      "</td><td>" +
      (c.title || "—") +
      "</td><td>" +
      (c.protocol || "—") +
      "</td><td>" +
      (c.location_id ?? "—") +
      "</td><td>" +
      (c.is_online ? "yes" : "no") +
      "</td>";
    tbody.appendChild(tr);

    const opt = document.createElement("option");
    opt.value = String(c.id);
    opt.textContent = "#" + c.id + " " + (c.title || "") + " (" + c.protocol + ")";
    opt.dataset.locationId = String(c.location_id ?? "");
    opt.dataset.protocol = c.protocol || "vless";
    select.appendChild(opt);
  });
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

function onConfigChange() {
  const opt = $("configSelect").selectedOptions[0];
  if (!opt) return;
  if (opt.dataset.locationId) $("locationSelect").value = opt.dataset.locationId;
  if (opt.dataset.protocol) {
    const p = $("protocolSelect");
    if ([...p.options].some((o) => o.value === opt.dataset.protocol)) {
      p.value = opt.dataset.protocol;
    }
  }
}

async function refreshAll() {
  try {
    const [state, configs, locations, response] = await Promise.all([
      fetchJson(EXT + "/state.json").catch(() => null),
      fetchJson(EXT + "/configs.json").catch(() => []),
      fetchJson(EXT + "/locations.json").catch(() => []),
      fetchJson(EXT + "/stealthsurf-response.json").catch(() => null),
    ]);
    renderState(state);
    const cfgList = Array.isArray(configs) ? configs : configs?.data || [];
    renderConfigs(cfgList);
    renderLocations(locations);
    if (response && response.message) {
      setMsg(response.message, response.status ? "ok" : "err");
    }
  } catch (e) {
    setMsg(String(e), "err");
  }
}

function bind() {
  $("configSelect").addEventListener("change", onConfigChange);
  $("btnSaveKey").addEventListener("click", () =>
    triggerService("setkey", { api_key: $("apiKey").value.trim() })
  );
  $("btnSync").addEventListener("click", () => triggerService("sync", {}));
  $("btnStart").addEventListener("click", () => triggerService("start", {}));
  $("btnStop").addEventListener("click", () => triggerService("stop", {}));
  $("btnRestart").addEventListener("click", () => triggerService("restart", {}));
  $("btnApply").addEventListener("click", () =>
    triggerService("apply", { config_id: Number($("configSelect").value) })
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
  $("btnRefresh").addEventListener("click", () => refreshAll());
}

bind();
refreshAll();
