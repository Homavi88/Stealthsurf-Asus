const $ = (html) => html;
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const app = document.querySelector("#app");
let S = null;
let ui = {
  stack: [],
  query: "",
  pop: false,
  toast: "",
  busy: false,
  busyCore: null,
  form: {},
  modal: null,
  result: null,
  showPass: false,
  auth: null, // null=loading, false=login, true=ok
  loginErr: "",
  loginBusy: false,
};
let es;

const fmt = (n) => {
  const v = Number(n) || 0;
  if (v < 1024) return `${Math.round(v)} Б/с`;
  if (v < 1024 * 1024) return `${(v / 1024).toFixed(v < 10240 ? 1 : 0)} КБ/с`;
  return `${(v / 1024 / 1024).toFixed(1)} МБ/с`;
};
const fmtBytes = (n) => {
  const v = Number(n) || 0;
  if (v < 1024) return `${v} Б`;
  if (v < 1024 * 1024) return `${(v / 1024).toFixed(1)} КБ`;
  if (v < 1024 ** 3) return `${(v / 1024 / 1024).toFixed(1)} МБ`;
  return `${(v / 1024 ** 3).toFixed(2)} ГБ`;
};
const mem = (n) => `${(Number(n) / 1024 / 1024 / 1024).toFixed(1)} ГБ`;

async function api(path, body) {
  const headers = { "X-EngVPN-Panel": "1" };
  if (body) headers["Content-Type"] = "application/json";
  const res = await fetch(path, {
    method: body ? "POST" : "GET",
    headers,
    credentials: "same-origin",
    cache: "no-store",
    body: body ? JSON.stringify(body) : undefined,
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok || data.ok === false) throw new Error(data.error || data.message || "Ошибка");
  return data;
}
function absorb(result) {
  if (result?.vpn && result?.subscriptions) S = result;
  else if (result?.state?.vpn) S = result.state;
}
async function invoke(cmd, body, opts = {}) {
  const data = await api(`/api/invoke/${cmd}`, body || {});
  absorb(data.result);
  if (!opts.quiet && (data.result?.vpn || data.result?.state?.vpn)) render();
  else if (!opts.quiet && !data.result?.vpn) {
    const snap = await api("/api/snapshot");
    S = snap;
    render();
  }
  return data.result;
}
function toast(msg, ms = 3200) {
  ui.toast = msg;
  render();
  setTimeout(() => { if (ui.toast === msg) { ui.toast = ""; render(); } }, ms);
}
async function run(fn) {
  try { await fn(); }
  catch (error) { toast(error.message || String(error), 6500); }
}

function applyTheme() {
  const a = S?.appearance || {};
  const theme = a.theme === "system"
    ? (matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark")
    : (a.theme || "dark");
  document.documentElement.dataset.theme = theme;
  document.documentElement.dataset.oled = a.oled && theme === "dark" ? "1" : "0";
  document.documentElement.dataset.accent = a.accent || "engvpn";
  if (!a.theme) document.documentElement.dataset.theme = "light";
  const icon = document.querySelector("link[rel=icon]");
  if (icon) {
    const svg = a.icon === "cat"
      ? `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="14" fill="#10141c"/><path d="M14 40l6-22 12 12 12-12 6 22" fill="none" stroke="#3b82f6" stroke-width="4"/></svg>`
      : a.icon === "bunny"
        ? `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="14" fill="#10141c"/><path d="M24 36c0-16 4-22 8-22s6 8 4 22M44 36c0-16-6-22-8-22" fill="none" stroke="#3b82f6" stroke-width="4"/><circle cx="32" cy="42" r="10" fill="none" stroke="#3b82f6" stroke-width="4"/></svg>`
        : a.icon === "surf"
          ? `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="14" fill="#10141c"/><path d="M10 42c12 8 32 8 44-6" fill="none" stroke="#3b82f6" stroke-width="4"/><circle cx="40" cy="22" r="4" fill="#3b82f6"/></svg>`
          : `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="14" fill="#10141c"/><circle cx="32" cy="32" r="14" fill="none" stroke="#3b82f6" stroke-width="3"/><path d="M18 32h28M32 18c5 5 5 22 0 28M32 18c-5 5-5 22 0 28" fill="none" stroke="#3b82f6" stroke-width="2"/></svg>`;
    icon.href = `data:image/svg+xml,${encodeURIComponent(svg)}`;
  }
}

function selected() {
  const active = (S.subscriptions || []).find((s) => s.id === S.activeSubscription);
  if (active) {
    const hit = (active.nodes || []).find((n) => n.id === S.vpn.selectedId);
    if (hit) return hit;
  }
  for (const sub of S.subscriptions || []) {
    const node = (sub.nodes || []).find((n) => n.id === S.vpn.selectedId);
    if (node) return node;
  }
  return (S.runtime?.nodes || []).find((n) => n.protocol !== "direct") || S.runtime?.nodes?.[0] || null;
}
function nodes() { return S.runtime?.nodes || []; }
function formatRub(v) {
  if (v == null || v === "") return "—";
  const n = Number(v);
  if (!Number.isFinite(n)) return `${esc(String(v))} ₽`;
  return `${n.toLocaleString("ru-RU", { maximumFractionDigits: 2 })} ₽`;
}
function pingOf(id) { return S.pings?.[id]?.ms; }

function flag(kind) {
  const cls = kind === "nl" ? "nl" : kind === "direct" ? "direct" : "auto";
  return `<i class="flag ${cls}"></i>`;
}
function hero(shape) {
  const head = shape === "diamond"
    ? `<path d="M100 42l58 66-58 66-58-66z"/>`
    : shape === "triangle"
      ? `<path d="M100 40l62 120H38z"/>`
      : `<circle cx="100" cy="112" r="64"/>`;
  return `<svg viewBox="0 0 200 220" fill="none" stroke="currentColor" stroke-width="5" stroke-linecap="round" stroke-linejoin="round">
    <path d="M46 108c-16 6-22 28-8 38M154 108c16 6 22 28 8 38"/>
    ${head}
    <path d="M58 86c14-30 70-34 92-6"/>
    <path d="M152 74l16-18 8 16"/>
    <rect x="74" y="104" width="14" height="30" rx="7" fill="currentColor" stroke="none"/>
    <rect x="112" y="104" width="14" height="30" rx="7" fill="currentColor" stroke="none"/>
    <path d="M84 150c8 12 24 12 32 0"/>
  </svg>`;
}
function logo() {
  const icon = S?.appearance?.icon || "base";
  if (icon === "cat") return `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M5 14l2-8 5 4 5-4 2 8"/><circle cx="9" cy="15" r="1"/><circle cx="15" cy="15" r="1"/></svg>`;
  if (icon === "bunny") return `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M8 11c0-5 2-8 3-8s2 3 1 8M16 11c0-5-2-8-3-8"/><circle cx="12" cy="15" r="5"/></svg>`;
  if (icon === "surf") return `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M4 16c4 2 12 2 16-2"/><circle cx="15" cy="8" r="2"/><path d="M8 14l4-6 2 2"/></svg>`;
  return `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3c3 3 3 15 0 18M12 3c-3 3-3 15 0 18"/></svg>`;
}
function gear() {
  return `<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="1.8"><circle cx="12" cy="12" r="3"/><path d="M12 3v2M12 19v2M3 12h2M19 12h2M5.6 5.6l1.4 1.4M17 17l1.4 1.4M18.4 5.6 17 7M7 17l-1.4 1.4"/></svg>`;
}
function spark(history) {
  const pts = (history || []).slice(-28);
  if (!pts.length) return `<svg class="spark" viewBox="0 0 92 28"></svg>`;
  const max = Math.max(1, ...pts.map((p) => p.vpnDown + p.vpnUp));
  const d = pts.map((p, i) => {
    const x = (i / Math.max(pts.length - 1, 1)) * 92;
    const y = 26 - ((p.vpnDown + p.vpnUp) / max) * 24;
    return `${x},${y}`;
  }).join(" ");
  return `<svg class="spark" viewBox="0 0 92 28"><polyline points="${d}" fill="none" stroke="#3b82f6" stroke-width="2"/></svg>`;
}

function sw(path, on) {
  return `<button type="button" class="switch ${on ? "on" : ""}" data-toggle="${path}" aria-pressed="${on ? "true" : "false"}"></button>`;
}
function cell(title, desc, control = "") {
  return `<div class="cell"><div class="cell-text"><div class="cell-title">${title}</div>${desc ? `<div class="cell-desc">${desc}</div>` : ""}</div>${control}</div>`;
}
function fieldBlock(title, desc, control) {
  return `<div class="field-block"><div class="cell-title">${title}</div>${desc ? `<div class="cell-desc">${desc}</div>` : ""}<div class="field-control">${control}</div></div>`;
}
function navRow(id, title, ico) {
  return `<button type="button" class="nav-item" data-go="${id}"><span class="nav-ico" aria-hidden="true">${ico}</span><span class="cell-text"><span class="nav-title">${esc(title)}</span></span><span class="chev">›</span></button>`;
}
function sel(path, value, options, full = false) {
  return `<select class="ctrl${full ? " full" : ""}" data-input="${esc(path)}">${options.map(([v, label]) => `<option value="${esc(v)}" ${String(v) === String(value) ? "selected" : ""}>${esc(label)}</option>`).join("")}</select>`;
}
function backBar(title) {
  return `<div class="drawer-bar"><button class="icon-btn" data-act="back" aria-label="Назад">‹</button><h2>${esc(title)}</h2><button class="icon-btn" data-act="close" aria-label="Закрыть">✕</button></div>`;
}

function screenMenu() {
  const q = (ui.query || "").toLowerCase();
  const match = (title) => !q || title.toLowerCase().includes(q);
  const groups = [
    [["router", "Роутер", "⌂"]],
    [
      ["subscription", "Подписка", "◎"],
      ["routing", "Маршрутизация", "⤳"],
      ["network", "Сеть и системные службы", "◍"],
      ["connection", "Подключение", "⇄"],
      ["automode", "Авторежим", "⟳"],
      ["netauto", "Автовыбор по сети", "▣"],
    ],
    [
      ["engine", "Движок", "⚙"],
      ["appearance", "Оформление", "◐"],
      ["other", "Другое", "⋯"],
    ],
    [
      ["updates", "Обновления", "↓"],
      ["feedback", "Предложить идею", "✦"],
      ["diagnostics", "Диагностика", "⌁"],
    ],
  ].map((g) => g.filter(([, title]) => match(title))).filter((g) => g.length);
  const email = S.account.email || "Аккаунт EngVPN";
  const bal = S.account.apiKeySet && S.account.balance != null ? ` · ${formatRub(S.account.balance)}` : "";
  const cfgN = S.account.apiKeySet && S.account.configsCount != null ? ` · ${S.account.configsCount} конфиг.` : "";
  const subLine = S.account.apiKeySet
    ? `${esc(S.account.subscriptionName || "Основная подписка (API)")}${bal}${cfgN}`
    : `${esc(S.account.subscriptionName || "Локальные подписки")} · API-ключ или URL`;
  const account = `<div class="nav-title">${esc(email)}</div><div class="cell-desc">${subLine}</div>`;
  return `<div class="drawer-bar"><h2>Настройки</h2><button class="icon-btn" data-act="close">✕</button></div>
    <div class="drawer-body">
      <div class="group"><button type="button" class="nav-item" data-go="account"><span class="nav-ico">☺</span><div class="cell-text">${account}</div><span class="chev">›</span></button></div>
      <div class="search"><span>⌕</span><input id="q" placeholder="Поиск настроек" value="${esc(ui.query)}"></div>
      ${groups.map((g) => `<div class="group">${g.map(([id, title, ico]) => navRow(id, title, ico)).join("")}</div>`).join("")}
    </div>`;
}

function screenAccount() {
  const a = S.account || {};
  const keySet = !!a.apiKeySet;
  const masked = a.apiKeyMasked || "";
  return `${backBar("Аккаунт")}<div class="drawer-body">
    <div class="card">
      <b>StealthSurf API</b>
      <p class="muted">Публичный HTTP API (<code>api.stealthsurf.net</code>). Ключ вида <code>stlth_…</code> — из кабинета StealthSurf. EngVPN не хранит пароль облака, только ваш Bearer-ключ на роутере.</p>
    </div>
    <div class="h">API-КЛЮЧ</div>
    <div class="group">
      ${keySet ? cell("Статус", `Активен · ${esc(masked)}`) : cell("Статус", "Не задан — покажите поля URL подписки ниже")}
      ${keySet ? cell("Баланс", formatRub(a.balance)) : ""}
      ${keySet && a.referralBalance != null ? cell("Реферальный баланс", formatRub(a.referralBalance)) : ""}
      ${keySet ? cell("Конфиги из API", a.configsCount != null ? `${esc(String(a.configsCount))} · список на главном экране` : "нажмите «Обновить конфиги»") : ""}
      ${keySet ? cell("Email", a.email || "—") : ""}
      <input class="text" id="apikey" type="password" placeholder="stlth_XXXXXXXX_…" autocomplete="off">
      <button class="primary" data-act="save-api-key">Сохранить ключ и синхронизировать</button>
      ${keySet ? `<button class="ghost" data-act="sync-account">Обновить конфиги из API</button><button class="danger" data-act="clear-api-key">Удалить ключ</button>` : ""}
    </div>
    ${!keySet ? `<div class="h">URL ПОДПИСКИ (БЕЗ КЛЮЧА)</div>
    <div class="group">
      <p class="muted">Если API-ключ пуст или неактивен — вставьте ссылку подписки или одиночный <code>vless://</code> / <code>trojan://</code>.</p>
      <input class="text" id="subname-acc" placeholder="Имя (необязательно)" value="Подписка по URL">
      <textarea class="text" id="suburl-acc" placeholder="https://… или vless:// / trojan:// / ss://">${esc(a.subscriptionUrl || "")}</textarea>
      <button class="primary" data-act="save-sub-url">Сохранить URL подписки</button>
    </div>` : `<div class="h">ДОП. URL ПОДПИСКИ</div>
    <div class="group">
      <p class="muted">Дополнительно можно держать локальный URL (раздел «Подписка»).</p>
      <button class="ghost" data-go="subscription">Открыть подписки</button>
    </div>`}
    <div class="h">НА РОУТЕРЕ</div>
    <div class="group">
      ${cell("Метка", "Только на этом роутере", `<input class="text" data-input="account.email" placeholder="например admin@home" value="${esc(a.email || "")}">`)}
      ${cell("Подписка", a.subscriptionName || "Локальные ссылки")}
      ${cell("Внутренний ID", S.routerId)}
    </div>
    <button class="ghost" data-act="pair">Код входа на другом устройстве LAN</button>
    ${ui.result?.code ? `<p class="muted">Код на 5 минут: <b>${esc(ui.result.code)}</b>. На другом устройстве введите его вместо пароля панели.</p>` : ""}
  </div>`;
}

function screenRouter() {
  const r = S.router;
  const marked = S.devices.filter((d) => d.excluded).length;
  const modeLabel = { off: "Выключено", all: "Все устройства", selected: "Только выбранные", except: "Все, кроме выбранных" }[r.mode];
  const modeText = {
    off: "Домашняя сеть идёт напрямую.",
    all: "Через VPN идут все устройства. PPTP и IPsec роутер отправляет напрямую: VPN несёт только TCP и UDP.",
    selected: "Через VPN идут только отмеченные устройства.",
    except: "Через VPN идут все устройства, кроме отмеченных. PPTP и IPsec идут напрямую.",
  }[r.mode];
  return `${backBar("Роутер")}<div class="drawer-body">
    <div class="group">
      <div class="mode-block">
        <div class="cell-title">VPN для всей сети</div>
        ${sel("router.mode", r.mode, [["off", "Выключено"], ["all", "Все устройства"], ["selected", "Только выбранные"], ["except", "Все, кроме выбранных"]], true)}
        <p class="muted">${modeText}</p>
      </div>
      ${cell("Статус", S.vpn.connected ? `Работает · через VPN ${fmtBytes((S.runtime.session.vpnDown || 0) + (S.runtime.session.vpnUp || 0))}` : "VPN выключен")}
      <button type="button" class="cell" data-go="devices"><div class="cell-text"><div class="cell-title">Устройства</div><div class="cell-desc">Отмечено ${marked} · режим «${esc(modeLabel)}»</div></div><span class="chev">›</span></button>
      <button type="button" class="cell" data-go="devices"><div class="cell-text"><div class="cell-title">Маршруты устройств</div><div class="cell-desc">Свой конфиг или сайты мимо VPN</div></div><span class="chev">›</span></button>
      ${cell("DNS через VPN", "Запросы адресов сайтов тоже идут через VPN", sw("router.dnsViaVpn", r.dnsViaVpn))}
      ${cell("Блокировать QUIC", "Браузеры уходят на TCP", sw("router.blockQuic", r.blockQuic))}
      ${cell("Не давать обходить DNS роутера", "Private Relay, частный DNS и известные DoH", sw("router.dnsLock", r.dnsLock))}
      ${cell("Игры с компьютеров — напрямую", "Списки Steam, Epic и других площадок", sw("router.gamesDirect", r.gamesDirect))}
      ${cell("Блокировать интернет без VPN", "Пока VPN выключен, наружу закрыто", sw("router.blockWithoutVpn", r.blockWithoutVpn))}
      ${cell("IPv6 устройств", "Через VPN, блокировать или напрямую", sel("router.ipv6", r.ipv6, [["vpn", "Через VPN"], ["block", "Блокировать"], ["direct", "Напрямую"]]))}
      ${cell("Метод transparent", "auto → TPROXY+UDP если xt_TPROXY есть, иначе REDIRECT", sel("router.transparentMethod", r.transparentMethod || "auto", [["auto", "Авто (TPROXY если можно)"], ["tproxy", "TPROXY + UDP"], ["redirect", "REDIRECT (только TCP)"]]))}
    </div>
    <div class="h">БЛОКИРОВКА РЕКЛАМЫ</div>
    <div class="group">
      ${cell("Блокировать рекламу", "И с VPN, и без него", sw("router.adblock", r.adblock))}
      ${cell("Заблокировано сегодня", String(r.adStats.today || 0))}
      ${cell("За 7 дней", String(r.adStats.week || 0))}
      <button type="button" class="cell" data-go="ads"><div class="cell-text"><div class="cell-title">Списки и исключения</div><div class="cell-desc">${(r.adStats.recent || []).slice(0, 2).map((x) => esc(x.host)).join(", ") || "свои сайты и белый список"}</div></div><span class="chev">›</span></button>
    </div>
    <div class="h">ПОЕЗДКИ</div>
    <div class="group">
      ${cell("Вход в сети отелей и кафе", "Если сеть просит портал, VPN гаснет", sw("router.trips", r.trips))}
      ${r.trips ? cell("Портал сейчас открыт", "Устройства идут напрямую", sw("router.captive", r.captive)) : ""}
    </div>
    <div class="h">ДОМАШНИЕ УСТРОЙСТВА</div>
    <div class="group">${cell("Включение по сети", "Magic packet на MAC", `<button class="ghost" data-go="wol">Открыть</button>`)}</div>
    <div class="h">HOME ASSISTANT</div>
    <div class="group">
      <p class="muted stub-inline">Опционально: MQTT публикуется локально, если указать брокер. Полный стек HA StealthSurf не требуется.</p>
      ${cell("Показывать VPN в Home Assistant", "Переключатель и датчики через MQTT", sw("router.ha", r.ha))}
      ${cell("Брокер MQTT", r.mqtt.host || "Не указан", `<button class="ghost" data-go="mqtt">Открыть</button>`)}
    </div>
    <div class="h">РАСПИСАНИЕ</div>
    <div class="group">
      ${cell("Только в выбранные часы", r.scheduleEnabled ? "Смотрите сетку часов" : "Сейчас VPN не ограничен часами", sw("router.scheduleEnabled", r.scheduleEnabled))}
      ${r.scheduleEnabled ? `<button class="ghost" data-go="schedule">Часы</button>` : ""}
    </div>
    <div class="h">РЕЗЕРВНЫЕ КОНФИГИ</div>
    <div class="group">${cell("Резерв 1", "Если текущий перестанет отвечать", sel("router.reserveId", r.reserveId, [["", "Не выбран"], ...nodes().filter((n) => n.protocol !== "direct").map((n) => [n.id, n.name])]))}</div>
    <div class="h">ENGVPN НА РОУТЕРЕ</div>
    <div class="group">
      <button type="button" class="cell" data-go="password"><div class="cell-text"><div class="cell-title">Пароль панели</div><div class="cell-desc">Нужен, чтобы открыть эту панель с устройств домашней сети</div></div><span class="chev">›</span></button>
      ${cell("Сохранить настройки в файл", "Режим, устройства, маршруты, расписания (JSON)", `<button class="ghost" data-act="export">Скачать</button>`)}
      ${cell("Загрузить настройки из файла", "Заменит текущие", `<input type="file" data-act="import" accept="application/json">`)}
      ${cell("Резервная копия пакета", "Архив data/ + конфиги через engvpnd backup", `<button class="ghost" data-act="backup-create">Создать</button>`)}
      ${cell("Последний бэкап", "Показать путь к последнему архиву", `<button class="ghost" data-act="backup-latest">Показать</button>`)}
    </div>
    <div class="h">О РОУТЕРЕ</div>
    <div class="group">
      ${aboutRow("Модель", S.about.model)}
      ${aboutRow("Прошивка", S.about.firmware)}
      ${aboutRow("Память", S.about.memory)}
      ${aboutRow("EngVPN", S.version)}
      ${aboutRow("Архитектура", S.about.arch)}
      ${aboutRow("ID", S.routerId)}
      ${aboutRow("Адрес панели", location.origin)}
      <p class="muted">Открытый стек: iptables + Xray/sing-box/mihomo. Без бинарников и облака StealthSurf.</p>
    </div>
  </div>`;
}
function aboutRow(k, v) {
  return `<div class="split"><span>${esc(k)}</span><button class="copy" data-copy="${esc(v)}">${esc(v)}</button></div>`;
}

function screenDevices() {
  const q = (ui.form.q || "").toLowerCase();
  const list = S.devices.filter((d) => `${d.name} ${d.ip} ${d.mac}`.toLowerCase().includes(q));
  const mode = { off: "Сеть напрямую", all: "Все устройства", selected: "Только выбранные", except: "Все, кроме выбранных" }[S.router.mode];
  return `${backBar("Устройства")}<div class="drawer-body">
    <div class="card"><b>${mode}</b><p>${S.router.mode === "except" ? "Отмеченные устройства выходят в интернет напрямую, остальные идут через VPN." : "Отметка выбирает, кто идёт через VPN."}</p></div>
    <div class="search"><span class="search-ico" aria-hidden="true">⌕</span><input id="devq" class="text" data-local="q" placeholder="Имя, IP или MAC-адрес" value="${esc(ui.form.q || "")}"></div>
    <div class="muted section-count">Устройства сети ${list.length} из ${S.devices.length}</div>
    <div class="device-list">
    ${list.map((d) => `<div class="cell device-row">
      <input type="checkbox" data-device="${d.id}" ${d.excluded ? "checked" : ""}>
      <button class="cell-text" data-go="device" data-id="${d.id}" style="background:none;border:0;color:inherit;text-align:left">
        <div class="cell-title">${esc(d.name)} ${d.isNew ? "<span class='beta'>новое</span>" : ""}</div>
        <div class="cell-desc"><span class="dot ${d.online ? "on" : "off"}" aria-hidden="true"></span> ${esc(d.ip)} · ${esc(d.mac)}</div>
      </button>
      <button type="button" class="icon-btn edit-btn" data-go="device" data-id="${d.id}" aria-label="Изменить">✎</button>
    </div>`).join("") || `<p class="muted">Пока пусто. Нажмите «Обновить список» — EngVPN читает ARP, соседей и dnsmasq leases.</p>`}
    </div>
    <button class="primary" data-act="scan-devices">Обновить список</button>
    <button class="ghost" data-act="add-device">Добавить устройство по IP</button>
  </div>`;
}

function screenDevice() {
  const d = S.devices.find((x) => x.id === ui.form.id);
  if (!d) return `${backBar("Устройство")}<div class="drawer-body">Нет устройства</div>`;
  return `${backBar(d.name)}<div class="drawer-body">
    <input class="text" data-rename="${d.id}" value="${esc(d.name)}">
    ${cell("IP", d.ip)} ${cell("MAC", d.mac)}
    ${cell("В списке исключений", "В режиме «все, кроме выбранных» отмеченное идёт напрямую", `<input type="checkbox" data-device="${d.id}" ${d.excluded ? "checked" : ""}>`)}
    ${cell("Свой маршрут", "", sel(`deviceRoute:${d.id}`, d.route, [["default", "Как у сети"], ["direct", "Всегда напрямую"], ["config", "Свой конфиг"]]))}
    ${d.route === "config" ? sel(`deviceConfig:${d.id}`, d.configId || "", nodes().map((n) => [n.id, n.name])) : ""}
    <div class="h">ТРАФИК</div>
    ${cell("Сеанс", fmtBytes(d.traffic.session))}
    ${cell("Сегодня", fmtBytes(d.traffic.today))}
    ${cell("7 дней", fmtBytes(d.traffic.d7))}
    ${cell("30 дней", fmtBytes(d.traffic.d30))}
    <div class="h">ПОЧЕМУ НЕ ОТКРЫВАЕТСЯ</div>
    <input class="text" id="why" placeholder="сайт, например youtube.com">
    <button class="primary" data-act="why" data-ip="${esc(d.ip)}">Проверить</button>
    ${ui.result?.reason ? `<p class="muted">${esc(ui.result.action)} — ${esc(ui.result.reason)}</p>` : ""}
    <div class="h">ЖУРНАЛ</div>
    ${(S.runtime.conns || []).filter((c) => c.deviceId === d.id || c.clientIp === d.ip).slice(0, 12).map((c) => `<div class="cell-desc">${esc(c.host)}:${c.port} → ${esc(c.action)} · ${esc(c.reason)}</div>`).join("") || `<p class="muted">Пока пусто. Журнал пишется, когда трафик идёт через прокси EngVPN.</p>`}
  </div>`;
}

function screenAds() {
  const r = S.router;
  const top = Object.entries(r.adStats.top || {}).sort((a, b) => b[1] - a[1]).slice(0, 6);
  return `${backBar("Реклама")}<div class="drawer-body">
    ${top.map(([h, n]) => cell(esc(h), String(n))).join("") || `<p class="muted">Счётчики вырастут, когда прокси или DNS EngVPN срежет рекламный домен.</p>`}
    <div class="h">СВОИ САЙТЫ</div>
    <textarea class="text" id="adcustom" placeholder="по домену в строке">${esc((r.adCustom || []).join("\n"))}</textarea>
    <button class="primary" data-act="save-ads" data-kind="adCustom">Сохранить свои сайты</button>
    <div class="h">НЕ БЛОКИРОВАТЬ</div>
    <textarea class="text" id="adwhite">${esc((r.adWhitelist || []).join("\n"))}</textarea>
    <button class="primary" data-act="save-ads" data-kind="adWhitelist">Сохранить белый список</button>
    <div class="h">ИСКЛЮЧЕНИЯ УСТРОЙСТВ</div>
    ${S.devices.map((d) => `<label class="cell"><input type="checkbox" data-adex="${d.id}" ${(r.adExcludeDevices || []).includes(d.id) ? "checked" : ""}><span>${esc(d.name)}</span></label>`).join("")}
  </div>`;
}

function screenWol() {
  return `${backBar("Включение по сети")}<div class="drawer-body">
    ${S.devices.map((d) => cell(esc(d.name), d.mac, `<button class="ghost" data-act="wol" data-mac="${esc(d.mac)}">Разбудить</button>`)).join("")}
  </div>`;
}
function screenMqtt() {
  const m = S.router.mqtt;
  return `${backBar("Брокер MQTT")}<div class="drawer-body">
    <input class="text" data-input="router.mqtt.host" placeholder="хост" value="${esc(m.host)}">
    <input class="text" data-input="router.mqtt.port" placeholder="порт" value="${esc(m.port || 1883)}">
    <input class="text" data-input="router.mqtt.username" placeholder="пользователь" value="${esc(m.username || "")}">
    <input class="text" data-input="router.mqtt.password" placeholder="пароль" type="password" value="${esc(m.password || "")}">
    <button class="primary" data-act="mqtt">Проверить публикацию</button>
    <p class="muted">${esc(m.status || "Нужны интеграция MQTT в Home Assistant и брокер, например Mosquitto.")}</p>
  </div>`;
}
function screenSchedule() {
  const hours = S.router.scheduleHours || [];
  return `${backBar("Расписание")}<div class="drawer-body"><div class="themes">${hours.map((on, h) => `<button class="theme-card ${on ? "on" : ""}" data-hour="${h}">${String(h).padStart(2, "0")}</button>`).join("")}</div>
  <p class="muted">Подсвеченный час — VPN можно держать включённым. Часы считаются по времени этой машины.</p></div>`;
}
function screenPassword() {
  return `${backBar("Пароль панели")}<div class="drawer-body">
    <input class="text" id="oldp" type="password" placeholder="Текущий пароль">
    <input class="text" id="newp" type="password" placeholder="Новый пароль">
    <button class="primary" data-act="password">Сохранить</button>
  </div>`;
}

function screenSubscription() {
  const api = S.account?.apiKeySet;
  return `${backBar("Подписка")}<div class="drawer-body">
    <div class="card">
      <b>${api ? "Основная подписка (API)" : "Локальные подписки"}</b>
      <p class="muted">${api
        ? "Конфиги подтягиваются через StealthSurf API-ключ в разделе «Аккаунт». Здесь же можно добавить свой URL."
        : "Задайте API-ключ в «Аккаунт» или вставьте URL / одиночный конфиг ниже."}</p>
    </div>
    <div class="group">
      ${cell("Активная подписка", "Список на роутере", sel("activeSub", S.activeSubscription, S.subscriptions.map((s) => [s.id, s.name])))}
      <p class="muted">Сейчас в списке ${nodes().length} конфигов.</p>
      <button class="ghost" data-act="refresh-sub">Обновить список</button>
      ${api ? `<button class="ghost" data-act="sync-account">Синхронизировать из API</button>` : ""}
    </div>
    <button class="nav-item" data-go="subadd">Добавить подписку <span class="chev">›</span></button>
    ${S.subscriptions.filter((s) => !s.builtin).map((s) => `<div class="cell">${esc(s.name)}<button class="danger" data-act="del-sub" data-id="${s.id}">Удалить</button></div>`).join("")}
  </div>`;
}
function screenSubAdd() {
  return `${backBar("Добавить подписку")}<div class="drawer-body">
    <input class="text" id="subname" placeholder="Имя">
    <textarea class="text" id="suburl" placeholder="https://… или vless:// / trojan:// / ss://"></textarea>
    <button class="primary" data-act="add-sub">Подключить</button>
    <p class="muted">Чужая подписка по имени и прямой ссылке. Одна строка конфига тоже подходит.</p>
  </div>`;
}

function screenRouting() {
  return `${backBar("Маршрутизация")}<div class="drawer-body">
    <button class="nav-item" data-go="rules">Маршрутизация трафика <span class="chev">›</span></button>
    <button class="nav-item" data-go="profiles">Профили подключения <span class="chev">›</span></button>
    <button class="nav-item" data-go="configroute">Маршрутизация выбранного конфига <span class="chev">›</span></button>
  </div>`;
}
function screenRules() {
  const r = S.routing;
  const local = r.source === "local";
  return `${backBar("Маршрутизация")}<div class="drawer-body">
    <div class="seg">
      <button class="${r.source === "server" ? "on" : ""}" data-source="server">Серверная</button>
      <button class="${local ? "on" : ""}" data-source="local">Локальная</button>
    </div>
    <p class="muted">${local ? "Правила только на этом устройстве. Пока они не применены, VPN живёт на старых." : "Правила этой EngVPN применяются сразу на локальном контуре. Сервер подписки сюда не подключён."}</p>
    ${local && r.localDirty ? `<button class="primary" data-act="apply-routing">Применить и переподключить</button>` : ""}
    <div class="group">
      ${cell("Маршрутизация на стороне клиента", "Гибкое управление. Поддерживается не всеми приложениями.", sw("routing.clientSide", r.clientSide))}
      ${cell("Автовыбор", "Сервер с наименьшим пингом. Приоритет обычным конфигам.", sw("routing.autoSelect", r.autoSelect))}
      ${cell("Балансировщики", "Свои автовыборы", `<button class="ghost" data-go="balancers">Открыть</button>`)}
    </div>
    <div class="h">ГЛОБАЛЬНЫЕ НАСТРОЙКИ</div>
    <div class="group">
      ${cell("Исключить российские сайты", ".ru, .su, .рф", sw("routing.excludeRu", r.excludeRu))}
      ${cell("Сервисы из белого списка напрямую", "Госуслуги, банки, VK, Яндекс, маркетплейсы, СМИ", sw("routing.whitelist", r.whitelist))}
      ${cell("Twitch напрямую", "", sw("routing.twitch", r.twitch))}
      ${cell("Spotify напрямую", "", sw("routing.spotify", r.spotify))}
      ${cell("Локальная сеть напрямую", "", sw("routing.lan", r.lan))}
      ${cell("Android Auto напрямую", "", sw("routing.androidAuto", r.androidAuto))}
      ${cell("BitTorrent напрямую", "Порты 6881–6999 и 51413", sw("routing.bittorrent", r.bittorrent))}
      ${cell("Загрузка игр напрямую", "Steam, Epic и другие площадки", sw("routing.games", r.games))}
      ${cell("Блокировка QUIC", "", sw("routing.blockQuic", r.blockQuic))}
      ${cell("Блокировка рекламы", "", sw("routing.blockAds", r.blockAds))}
      ${cell("Блокировка порносайтов", "", sw("routing.blockPorn", r.blockPorn))}
      ${cell("Фрагментация", "Только если подключение не устанавливается. Пишется в конфиг Xray.", sw("routing.fragment", r.fragment))}
      ${cell("Пользовательские правила", "Домены, IP, geosite и geoip", `<button class="ghost" data-go="customrules">Открыть</button>`)}
      ${cell("Управление DNS", "", sel("routing.dnsProvider", r.dnsProvider, [["cloudflare", "Cloudflare"], ["google", "Google"], ["quad9", "Quad9"], ["adguard", "AdGuard"]]))}
      ${cell("Резервный DNS", "", sel("routing.dnsFallback", r.dnsFallback, [["google", "Google"], ["cloudflare", "Cloudflare"], ["quad9", "Quad9"]]))}
    </div>
  </div>`;
}
function screenCustom() {
  const rules = S.routing.custom || [];
  return `${backBar("Свои правила")}<div class="drawer-body">
    ${rules.map((r) => `<div class="cell"><div class="cell-text"><b>${esc(r.action)}</b><div class="cell-desc">${esc((r.conditions || []).map((c) => `${c.kind}:${c.value}`).join(", "))}</div></div><button class="danger" data-act="del-rule" data-id="${r.id}">✕</button></div>`).join("") || `<p class="muted">Правил пока нет.</p>`}
    ${sel("draft-action", ui.form.action || "direct", [["direct", "Напрямую"], ["proxy", "В VPN"], ["block", "Забанить"]])}
    ${sel("draft-kind", ui.form.kind || "domain", [["domain", "Домен"], ["geosite", "geosite"], ["ip", "IP или подсеть"], ["geoip", "geoip"], ["protocol", "Протокол"], ["port", "Порт"]])}
    <input class="text" id="ruleval" placeholder="example.com, geosite:youtube, 10.0.0.0/8">
    <button class="primary" data-act="add-rule">Добавить</button>
    <p class="muted">Синтаксис как у Xray: domain:, geosite:, geoip:, отрицание через ! в поле домена. geoip, кроме private, на краю EngVPN не разбирается по базе MaxMind — полная база отдаётся ядру в файле geoip.dat.</p>
  </div>`;
}
function screenBalancers() {
  return `${backBar("Балансировщики")}<div class="drawer-body">
    ${(S.routing.balancers || []).map((b) => `<div class="cell"><div class="cell-text"><b>${esc(b.name)}</b><div class="cell-desc">${b.servers.length} серверов</div></div><button data-act="use-bal" data-id="${b.id}">Выбрать лучший</button><button class="danger" data-act="del-bal" data-id="${b.id}">✕</button></div>`).join("")}
    <input class="text" id="balname" placeholder="Имя">
    ${nodes().filter((n) => n.protocol !== "direct").map((n) => `<label class="cell"><input type="checkbox" class="bal" value="${n.id}"><span>${esc(n.name)}</span></label>`).join("")}
    <button class="primary" data-act="add-bal">Сохранить балансировщик</button>
  </div>`;
}
function screenProfiles() {
  return `${backBar("Профили подключения")}<div class="drawer-body">
    <button class="primary" data-act="save-profile">Сохранить текущие настройки подключения</button>
    ${(S.profiles || []).map((p) => `<div class="cell"><div class="cell-text"><b>${esc(p.name)}</b></div><button data-act="apply-profile" data-id="${p.id}">Включить</button><button class="danger" data-act="del-profile" data-id="${p.id}">✕</button></div>`).join("")}
  </div>`;
}
function screenConfigRoute() {
  const node = selected();
  const pack = (S.configRoutes || {})[node?.id] || { rules: [] };
  const tags = ["Великобритания", "США", "Польша", "Нидерланды", "YouTube без рекламы", "Gemini", "Напрямую", "Забанить"];
  return `${backBar("Маршрутизация (сервер)")}<div class="drawer-body">
    <div class="card"><b>Информация</b><p>Доступные теги: ${tags.join(", ")}. domain: захватывает поддомены. geosite: и geoip: поддерживаются синтаксисом Xray. Отрицание — восклицательный знак.</p></div>
    <button class="ghost" data-act="import-rules">Импортировать</button>
    <button class="ghost" data-act="copy-rules">Скопировать</button>
    <button class="ghost" data-act="download-rules">Скачать файлом</button>
    <button class="ghost" data-act="add-pool">Добавить прокси из пула</button>
    <div class="h">ПРАВИЛА</div>
    ${pack.rules.map((r, i) => `<div class="card"><div class="cell-title">${esc(r.tag)}</div><div class="cell-desc">${esc(r.protocol || "любой")} ${esc((r.domains || []).join(" "))}</div><button class="danger" data-act="drop-cr" data-i="${i}">Удалить</button></div>`).join("")}
    ${sel("cr-tag", "Забанить", tags.map((t) => [t, t]))}
    <input class="text" id="crdom" placeholder="domain:example.com или geosite:youtube">
    ${sel("cr-proto", "any", [["any", "Любой протокол"], ["bittorrent", "BitTorrent"], ["tcp", "TCP"], ["udp", "UDP"]])}
    <button class="ghost" data-act="add-cr">Добавить правило</button>
    <button class="primary" data-act="save-cr">Применить</button>
  </div>`;
}

function screenNetwork() {
  const n = S.network;
  const sd = S.smartdns || { enabled: false, entries: [] };
  return `${backBar("Сеть и системные службы")}<div class="drawer-body"><div class="group">
    ${cell("YouTube через zapret", "Напрямую, а если путь не работает — через VPN", sw("network.youtubeZapret", n.youtubeZapret))}
    ${cell("Discord через zapret", "Вместе с голосовыми каналами", sw("network.discordZapret", n.discordZapret))}
    ${cell("Расширенные настройки zapret", "Свои списки и проверка пути", `<button class="ghost" data-go="zapret">Открыть</button>`)}
    ${cell("Telegram напрямую", "Прямой путь", sw("network.telegramDirect", n.telegramDirect))}
  </div>
  <div class="h">SMARTDNS — МИМО VPN</div>
  <div class="group">
    ${cell("Обход по списку", "Домены и IP идут напрямую (iptables RETURN + routing direct)", sw("smartdns.enabled", !!sd.enabled))}
    <div class="field-block">
      <div class="cell-title">Список доменов и IP</div>
      <div class="cell-desc">По одному на строку: example.com, 1.2.3.4, 10.0.0.0/8</div>
      <textarea class="text" id="smartdns-list" placeholder="telegram.org&#10;1.1.1.1">${esc((sd.entries || []).join("\n"))}</textarea>
      <button class="primary" data-act="save-smartdns">Сохранить и применить</button>
    </div>
  </div>
  <p class="muted">Обход блокировок: открытый <b>zapret/nfqws</b> через <code>engvpnd dpi</code>. SmartDNS — локальный список EngVPN (не консоль StealthSurf).</p></div>`;
}
function screenZapret() {
  const z = S.network.zapret;
  const ways = Object.entries(z.serviceWays || {});
  return `${backBar("Настройки zapret")}<div class="drawer-body">
    <div class="card"><b>Эта сеть</b><p>Ethernet. «Перепроверить» подтверждает TCP-путь. «Проверить все способы» проходит по сервисам и, если путь молчит, помечает запасной VPN.</p>
    <button class="ghost" data-act="zapret" data-all="0">Перепроверить</button>
    <button class="ghost" data-act="zapret" data-all="1">Проверить все способы</button></div>
    <div class="h">СПОСОБЫ ДЛЯ СЕРВИСОВ</div>
    ${ways.length ? ways.map(([k, v]) => cell(esc(k), v === "vpn" ? "запасной VPN" : "прямой путь")).join("") : `<p class="muted">Включите YouTube, Discord или свой список — здесь появится результат проверки.</p>`}
    <div class="h">СВОИ СПИСКИ</div>
    ${(z.lists || []).map((l) => cell(esc(l.name), (l.domains || []).join(", "))).join("")}
    <input class="text" id="zname" placeholder="Название списка">
    <textarea class="text" id="zdom" placeholder="домены через пробел"></textarea>
    <button class="primary" data-act="zapret-list">Добавить список</button>
    <div class="h">СВОИ СПОСОБЫ</div>
    ${(z.methods || []).map((m) => cell(esc(m.name), esc(m.note))).join("")}
    ${sel("zkind", "direct", [["direct", "Прямой путь"], ["vpn", "Запасной VPN"]])}
    <input class="text" id="zmethod" placeholder="Имя способа">
    <button class="ghost" data-act="zapret-method">Сохранить способ</button>
    <button class="danger" data-act="zapret-reset">Сбросить закрепления</button>
  </div>`;
}

function screenConnection() {
  const c = S.connection;
  return `${backBar("Подключение")}<div class="drawer-body"><div class="group">
    ${cell("Подключать VPN при включении", "После перезапуска панели", sw("connection.onBoot", c.onBoot))}
    ${cell("Подключаться при выборе конфига", "", sw("connection.onSelect", c.onSelect))}
    ${cell("Не использовать IPv6", "Только IPv4 до сервера", sw("connection.ipv4Only", c.ipv4Only))}
    ${cell("Раздавать VPN в локальную сеть", "Прокси слушает все интерфейсы", sw("connection.shareLan", c.shareLan))}
  </div>
  <div class="h">CLOUDFLARE WARP</div>
  <div class="group">
    <p class="muted">Открытая регистрация Cloudflare WARP (как wgcf) → WireGuard-профиль для sing-box / mihomo. Без закрытого стека StealthSurf.</p>
    ${cell("Режим", "Прокси / внутри туннеля / выкл.", sel("connection.warpMode", c.warpMode, [["off", "Выключен"], ["proxy", "Прокси"], ["tunnel", "Внутри туннеля"]]))}
    ${cell("Способ", "WireGuard (открытый)", sel("connection.warpMethod", c.warpMethod || "wireguard", [["wireguard", "WireGuard"], ["amneziawg", "AmneziaWG"], ["auto", "Авто"]]))}
    <p class="muted">${c.warpProfile ? `Профиль: ${esc(c.warpProfile.status || "есть")}` : "Профиль ещё не создан."}</p>
    <button class="primary" data-act="warp-create">Создать профиль WARP</button>
    <textarea class="text" id="warpini" placeholder="[Interface] PrivateKey=… [Peer] PublicKey=… Endpoint=…"></textarea>
    <button class="ghost" data-act="warp-import">Импортировать профиль</button>
  </div>
  <div class="h">GRE (РЕЗЕРВ)</div>
  <div class="group">
    <p class="muted">Опциональный GRE-туннель: заполните <code>data/gre.conf</code> и поднимите через CLI.</p>
    <button class="ghost" data-act="gre-up">GRE up</button>
    <button class="ghost" data-act="gre-down">GRE down</button>
  </div>
  <div class="h">МУЛЬТИПЛЕКСИРОВАНИЕ (MUX)</div>
  <div class="group">
    <p class="muted">Несколько общих соединений к серверу. Загрузки могут стать медленнее. Только Xray и если сервер умеет MUX.</p>
    <div class="seg">
      ${["subscription", "off", "custom"].map((id) => `<button class="${c.mux === id ? "on" : ""}" data-mux="${id}">${{ subscription: "Из подписки", off: "Выключен", custom: "Свой" }[id]}</button>`).join("")}
    </div>
    ${c.mux === "custom" ? `<input class="text" data-input="connection.muxConcurrency" value="${esc(c.muxConcurrency)}">` : ""}
  </div>
  <div class="h">МОСТЫ</div>
  <div class="group">
    <p class="muted">Подключение к конфигу через другой, если провайдер блокирует его сервер. В конфиге Xray это dialerProxy.</p>
    ${(c.bridges || []).map((b) => `<div class="cell">${esc(b.from)} → ${esc(b.to)} <button class="danger" data-act="del-bridge" data-id="${b.id}">✕</button></div>`).join("")}
    ${sel("bridge-to", "", nodes().map((n) => [n.id, n.name]))}
    <button class="ghost" data-act="add-bridge">Добавить мост к выбранному</button>
  </div></div>`;
}

function screenAutomode() {
  const a = S.automode;
  return `${backBar("Авторежим")}<div class="drawer-body"><div class="group">
    <p class="muted">Подбор протокола и настроек: какие серверы отвечают, перебор, пока не найдётся рабочий.</p>
    ${sel("automode.configId", a.configId, [["", "Не выбран"], ...nodes().filter((n) => n.protocol !== "direct").map((n) => [n.id, n.name])])}
    ${cell("Авторежим", a.configId ? "Можно запускать" : "Сначала выберите конфиг", sw("automode.enabled", a.enabled))}
    <button class="primary" data-act="automode">Подобрать сейчас</button>
    ${(a.log || []).map((row) => `<div class="cell-desc">${esc(row.name)} · ${esc(row.engine)} · ${row.ms == null ? "нет ответа" : `${row.ms} мс`}${row.picked ? " · выбран" : ""}</div>`).join("")}
  </div></div>`;
}
function screenNetAuto() {
  const n = S.netAuto;
  const opts = [["", "Не назначен"], ["direct", "Напрямую"], ...nodes().filter((x) => x.protocol !== "direct").map((x) => [x.id, x.name])];
  return `${backBar("Автовыбор по сети")}<div class="drawer-body"><div class="group">
    ${cell("Сейчас", n.current === "lte" ? "Резервный LTE" : "Ethernet")}
    ${cell("По умолчанию", "", sel("netAuto.rules.default", n.rules.default, opts))}
    ${cell("Ethernet", "", sel("netAuto.rules.ethernet", n.rules.ethernet, opts))}
    ${cell("Резервный LTE", "", sel("netAuto.rules.lte", n.rules.lte, opts))}
    ${cell("Автопереключение", "Сначала выберите действие по умолчанию", sw("netAuto.enabled", n.enabled))}
    <button class="ghost" data-act="detect-net">Определить текущую сеть</button>
  </div></div>`;
}

function screenEngine() {
  const e = S.engine;
  const cores = S.runtime.cores || {};
  const pref = e.preference;
  return `${backBar("Движок")}<div class="drawer-body">
    <p class="muted">Авто подключает каждый конфиг подходящим ядром. Xray — полная маршрутизация (без WG/AWG). <b>Ferrum</b> — открытый слот: скачивает Xray-core (Reality) как <code>data/cores/ferrum</code>. sing-box / mihomo — конвертация; mihomo умеет AmneziaWG.</p>
    <div class="seg">
      ${["auto", "xray", "ferrum", "sing-box", "mihomo"].map((id) => `<button class="${pref === id ? "on" : ""}" data-engine="${id}">${id === "auto" ? "Авто" : id === "sing-box" ? "sing-box" : id[0].toUpperCase() + id.slice(1)}</button>`).join("")}
    </div>
    <p class="muted">${esc(S.runtime.engineMessage || e.activeReason || "Туннель ещё не поднимался")}</p>
    <div class="h">РАЗРЕШЕНИЕ ИМЁН</div>
    ${cell("Доменная стратегия", "Авто берёт AsIs, а с FakeIP — IPIfNonMatch", sel("engine.domainStrategy", e.domainStrategy, [["auto", "Авто"], ["AsIs", "AsIs"], ["IPIfNonMatch", "IPIfNonMatch"], ["IPOnDemand", "IPOnDemand"]]))}
    ${cell("FakeIP", "Временные адреса 198.18.0.0/15, имя решает VPN. Включается со следующего подключения.", sw("engine.fakeIp", e.fakeIp))}
    <div class="h">ЛОКАЛЬНЫЙ ПРОКСИ</div>
    <div class="group">
      ${fieldBlock("SOCKS / смешанный", "Если занят, берётся ближайший свободный", `<input class="text" data-input="engine.socksPort" inputmode="numeric" value="${esc(e.socksPort)}">`)}
      ${fieldBlock("HTTP-порт Xray", "sing-box и mihomo для обоих протоколов используют смешанный порт", `<input class="text" data-input="engine.httpPort" inputmode="numeric" value="${esc(e.httpPort)}">`)}
    </div>
    <p class="muted">Сейчас слушают SOCKS ${S.runtime.socksPort || "—"} и HTTP ${S.runtime.httpPort || "—"}. DNS EngVPN: порт 5353.</p>
    <div class="h">ГЕО-БАЗЫ</div>
    <div class="seg">
      <button class="${e.geoSource === "standard" ? "on" : ""}" data-geo="standard">Стандартная</button>
      <button class="${e.geoSource === "custom" ? "on" : ""}" data-geo="custom">Свой URL</button>
    </div>
    ${e.geoSource === "custom" ? `<input class="text" data-input="engine.geoUrl" placeholder="https://…/geosite.dat" value="${esc(e.geoUrl || "")}">` : ""}
    ${cell("Базы", `geosite ${fmtBytes(e.geo.geosite)} · geoip ${fmtBytes(e.geo.geoip)}`, `<button class="ghost" data-act="geo">Обновить</button>`)}
    <div class="h">ЗАГРУЖЕННЫЕ ЯДРА</div>
    ${["xray", "ferrum", "sing-box", "mihomo"].map((id) => {
      const c = cores[id] || {};
      const busy = ui.busyCore === id;
      return `<div class="card core-card"><b>${esc(c.title || id)}</b><p>Эталон снимка: ${esc(c.ref || "")}. ${c.installed ? `Файл ${fmtBytes(c.bytes)}. ${esc(c.version || "")}` : "Не скачано"}</p>
        <button class="ghost${busy ? " busy" : ""}" data-act="get-core" data-id="${id}" ${busy ? "disabled" : ""}>${busy ? "Скачиваю…" : id === "ferrum" ? "Скачать (Xray Reality)" : "Скачать"}</button>
        ${c.installed ? `<button class="ghost" data-act="test-core" data-id="${id}">Проверить конфиг</button><button class="danger" data-act="del-core" data-id="${id}">Удалить</button>` : ""}
      </div>`;
    }).join("")}
    <button class="ghost" data-go="xray">Открыть собранный конфиг</button>
  </div>`;
}

function screenLook() {
  const a = S.appearance;
  const themes = [["system", "Системная"], ["light", "Светлая"], ["dark", "Тёмная"], ["retro", "Ретро"], ["halloween", "Хэллоуин"]];
  return `${backBar("Оформление")}<div class="drawer-body">
    <p class="muted">Светлая тема — отдельный режим панели. Можно включить здесь или через «Системная», если в телефоне светлый режим.</p>
    <div class="themes">${themes.map(([id, label]) => `<button class="theme-card ${a.theme === id ? "on" : ""}" data-theme="${id}"><div class="swatch" data-sw="${id}"></div>${label}</button>`).join("")}</div>
    ${cell("Акцентная тема", "Цвет кнопок и ссылок", sel("appearance.accent", a.accent, [["engvpn", "EngVPN"], ["ocean", "Океан"], ["ember", "Уголь"], ["mint", "Мята"]]))}
    <div class="h">ИКОНКА ПАНЕЛИ</div>
    <div class="icons">
      ${[["base", "База"], ["surf", "Сёрфик"], ["cat", "Котик"], ["bunny", "Зайка"]].map(([id, label]) => `<button class="icon-card ${a.icon === id ? "on" : ""}" data-icon="${id}">${label}</button>`).join("")}
    </div>
    <p class="muted">Значок виден на вкладке. На работу маршрутов не влияет.</p>
    ${cell("Чёрная тема", "Чистый чёрный фон для OLED (только тёмная)", sw("appearance.oled", a.oled))}
  </div>`;
}
function screenOther() {
  const o = S.other;
  return `${backBar("Другое")}<div class="drawer-body">
    <div class="group">
      ${cell("Автонастройка", "Если конфиг замолчал, подобрать другой. Тумблер на главной сам функцию не включает.", sw("other.autoSetup", o.autoSetup))}
      ${cell("«Автонастройка» на главной", "", sw("other.showAutoToggle", o.showAutoToggle))}
    </div>
    <div class="group">
      ${cell("Живая кнопка подключения", "", sw("other.liveButton", o.liveButton))}
      ${cell("График скорости", "", sw("other.speedChart", o.speedChart))}
      ${cell("Показывать пинг конфигов", "", sw("other.showPing", o.showPing))}
    </div>
  </div>`;
}
function screenUpdates() {
  const u = S.updates;
  return `${backBar("Обновления")}<div class="drawer-body"><div class="group">
    ${cell("Автообновление", `По умолчанию выкл. При включении — engvpnd update в окне ${String(u.windowStart ?? 2).padStart(2, "0")}:00–${String(u.windowEnd ?? 5).padStart(2, "0")}:00 (SHA-256 + Minisign)`, sw("updates.auto", !!u.auto))}
    ${cell("Гео-базы раз в неделю", "", sw("updates.geoWeekly", u.geoWeekly))}
    ${cell("Качать ядра, когда их нет", "", sw("updates.coresWhenMissing", u.coresWhenMissing))}
    ${cell("Интервал проверки", "Merlin cru / cron · переживает перезагрузку", sel("updates.interval", u.interval || "1d", [["6h", "Каждые 6 часов"], ["12h", "Каждые 12 часов"], ["1d", "Раз в сутки"], ["3d", "Раз в 3 дня"], ["7d", "Раз в неделю"], ["off", "Выкл."]]))}
    <button class="primary" data-act="check-updates">Проверить сейчас</button>
    <p class="muted">Текущая сборка ${esc(S.version)}. Feed EngVPN (SHA-256 + Minisign). Последняя проверка: ${u.lastCheck ? new Date(u.lastCheck).toLocaleString() : "ещё не было"}.${u.lastResult ? ` · ${esc(u.lastResult)}` : ""}${u.note ? ` ${esc(u.note)}` : ""}</p>
  </div></div>`;
}
function screenFeedback() {
  return `${backBar("Предложить идею")}<div class="drawer-body">
    <textarea class="text" id="idea" maxlength="4000" placeholder="Текст до 4000 символов"></textarea>
    <input type="file" id="ideafiles" multiple>
    <button class="primary" data-act="feedback">Отправить в журнал EngVPN</button>
    <button class="ghost" data-act="support">Написать в поддержку</button>
    <p class="muted">Это не поддержка. Сообщение остаётся в файле этой панели, наружу не отправляется. До 5 файлов по 10 МБ.</p>
    ${(S.feedback || []).slice(0, 5).map((f) => `<div class="cell-desc">${esc(f.text.slice(0, 140))}</div>`).join("")}
  </div>`;
}
function screenDiag() {
  const d = S.diagnostics;
  return `${backBar("Диагностика")}<div class="drawer-body"><div class="group">
    ${cell("Тест скорости", "Пинг, загрузка через VPN и напрямую", `<button class="ghost" data-act="speedtest">Запустить</button>`)}
    ${ui.result?.direct ? `<p class="muted">Напрямую: пинг ${ui.result.direct.ping ?? "—"} мс, ${ui.result.direct.down || 0} Б/с. VPN: ${ui.result.vpn ? (ui.result.vpn.down || ui.result.vpn.error) : "не подключён"}. ЦП ${ui.result.cpu}%.</p>` : ""}
    ${cell("Проверка утечек", "DNS и IPv6", `<button class="ghost" data-act="leak">Проверить</button>`)}
    ${ui.result?.dns ? `<p class="muted">${esc(JSON.stringify(ui.result.dns))} ${esc(ui.result.note || "")}</p>` : ""}
    ${cell("Нагрузка на роутер", "Пока панель открыта", sw("diagnostics.showLoad", d.showLoad))}
    ${cell("Режим разработчика", "Логи ядра и подробности", sw("diagnostics.devMode", d.devMode))}
    ${cell("Отправлять отчёты об ошибках", "В EngVPN отчёты остаются локально", sw("diagnostics.errorReports", d.errorReports))}
    ${cell("Проверка туннеля после подключения", "Три неудачи подряд включают резерв или автонастройку", sw("diagnostics.tunnelCheck", d.tunnelCheck))}
    ${cell("Логи подключения", "Чистятся при каждом подключении", `<button class="ghost" data-go="logs">Открыть</button>`)}
    ${cell("Сбросить сетевые настройки", "MTU, IPv6, порты, системный прокси", `<button class="danger" data-act="reset-net">Сбросить</button>`)}
    <p class="muted">Версия ${esc(S.version)}. Ядра: Xray ${esc(S.runtime.cores?.xray?.version || "нет")}, sing-box ${esc(S.runtime.cores?.["sing-box"]?.version || "нет")}, mihomo ${esc(S.runtime.cores?.mihomo?.version || "нет")}.</p>
  </div></div>`;
}
function screenLogs() {
  const rows = S.diagnostics.devMode ? S.logs : S.logs.filter((l) => l.level !== "debug");
  return `${backBar("Логи подключения")}<div class="drawer-body">
    <button class="ghost" data-act="clear-logs">Очистить</button>
    ${rows.slice(0, 80).map((l) => `<div class="cell-desc">${new Date(l.t).toLocaleTimeString()} ${esc(l.level)} ${esc(l.msg)}</div>`).join("") || `<p class="muted">Пусто</p>`}
    ${S.diagnostics.devMode ? `<p class="muted">Deep link EngVPN: engvpn://connect/${esc(S.vpn.selectedId)}</p>` : ""}
  </div>`;
}
function screenXray() {
  const text = ui.result?.text || "Конфиг появится после подключения или кнопки ниже.";
  return `${backBar("Xray-конфиг")}<div class="drawer-body">
    <button class="ghost" data-act="load-config">Показать собранные конфиги</button>
    <pre class="config">${esc(text)}</pre>
  </div>`;
}
function screenSpeed() {
  const h = S.runtime.history || [];
  const max = Math.max(1, ...h.map((p) => p.vpnDown + p.directDown));
  const line = (key) => h.map((p, i) => `${(i / Math.max(h.length - 1, 1)) * 320},${150 - (p[key] / max) * 140}`).join(" ");
  const sum = (k) => h.reduce((a, p) => a + (p[k] || 0), 0);
  return `${backBar("Скорость")}<div class="drawer-body">
    <svg class="chart-big" viewBox="0 0 320 160"><polyline points="${line("vpnDown")}" fill="none" stroke="#3b82f6" stroke-width="2"/><polyline points="${line("directDown")}" fill="none" stroke="#94a3b8" stroke-width="2"/></svg>
    ${cell("Пик VPN", fmt(Math.max(0, ...h.map((p) => p.vpnDown))))}
    ${cell("За окно графика через VPN", fmtBytes(sum("vpnDown") + sum("vpnUp")))}
    ${cell("Напрямую", fmtBytes(sum("directDown") + sum("directUp")))}
    ${cell("Сессия VPN", fmtBytes((S.runtime.session.vpnDown || 0) + (S.runtime.session.vpnUp || 0)))}
    <p class="muted">Синяя линия — через VPN, серая — напрямую. Окно около двух минут.</p>
  </div>`;
}
function screenTelegram() {
  const ready = S.network.telegramDirect && S.network.zapret.serviceWays.telegram !== "vpn";
  return `${backBar("Telegram")}<div class="drawer-body"><div class="card"><b>${ready ? "Прямой путь готов" : "Пойдёт через VPN"}</b><p>${ready ? "Когда Telegram подключится, он пойдёт мимо VPN и будет видеть домашний IP. Если путь сломается — вернётся в VPN." : "Прямой путь выключен в разделе сети."}</p></div></div>`;
}

const screens = {
  menu: screenMenu,
  account: screenAccount,
  router: screenRouter,
  devices: screenDevices,
  device: screenDevice,
  ads: screenAds,
  wol: screenWol,
  mqtt: screenMqtt,
  schedule: screenSchedule,
  password: screenPassword,
  subscription: screenSubscription,
  subadd: screenSubAdd,
  routing: screenRouting,
  rules: screenRules,
  customrules: screenCustom,
  balancers: screenBalancers,
  profiles: screenProfiles,
  configroute: screenConfigRoute,
  network: screenNetwork,
  zapret: screenZapret,
  connection: screenConnection,
  automode: screenAutomode,
  netauto: screenNetAuto,
  engine: screenEngine,
  appearance: screenLook,
  other: screenOther,
  updates: screenUpdates,
  feedback: screenFeedback,
  diagnostics: screenDiag,
  logs: screenLogs,
  xray: screenXray,
  speed: screenSpeed,
  telegram: screenTelegram,
};

function home() {
  const node = selected();
  const rt = S.runtime;
  const connected = S.vpn.connected;
  const direct = S.vpn.directMode;
  const label = connected ? "Подключено" : direct ? "Без VPN" : "Отключено";
  const ip = (connected ? rt.exitIp : rt.publicIp) || "—";
  const shape = connected ? "round" : direct ? "diamond" : "triangle";
  const news = S.devices.filter((d) => d.isNew && !S.dismissedNew.includes(d.id));
  const rates = rt.rates || {};
  return `<div class="shell">
    <div class="topbar"><div class="brand">${logo()} EngVPN</div><div class="spacer"></div>
      <button class="icon-btn" data-act="settings" aria-label="Настройки">${gear()}</button></div>
    <div class="layout">
      <div class="center">
        <div class="hero-wrap">
          <button class="hero-btn ${S.other.liveButton ? "live" : ""}" data-act="toggle" ${ui.busy ? "disabled" : ""}>${hero(shape)}</button>
          <h2 class="status">${label}</h2>
          <button class="ip-pill" data-act="ip">${flag(node?.flag || "auto")} ${esc(ip)}</button>
          ${S.diagnostics.showLoad ? `<div class="loadline" data-live="load">ЦП ${rt.load.cpu}% · ОЗУ ${mem(rt.load.ramUsed)}/${mem(rt.load.ramTotal)} · EngVPN ${fmtBytes(rt.load.proc)}</div>` : `<div class="loadline"></div>`}
        </div>
        ${S.other.speedChart ? `<div class="card"><button class="card-btn" data-go-root="speed"><div class="speed-grid"><div><div class="card-head"><span class="card-ico">↓</span><h3>Скорость</h3></div>
          <div class="muted kv" data-live="speed">VPN ↓ ${fmt(rates.vpnDown)} ↑ ${fmt(rates.vpnUp)}<br>Напрямую ↓ ${fmt(rates.directDown)} ↑ ${fmt(rates.directUp)}</div></div>
          <span data-live="spark">${spark(rt.history)}</span><span class="chev">›</span></div></button></div>` : ""}
        <div class="card"><button class="card-btn" data-go-root="telegram"><div class="card-head"><span class="card-ico">✈</span><div><h3>${S.network.telegramDirect ? "Прямой путь к Telegram готов" : "Telegram через VPN"}</h3><p>Telegram пойдёт напрямую, как только подключится</p></div><span class="chev">›</span></div></button></div>
        ${news.length ? `<div class="card"><button class="card-btn" data-act="new-devices"><div class="card-head"><span class="card-ico">⌂</span><div><h3>Новое устройство в сети</h3><p>${esc(news[0].ip)} · маршрут через VPN · ещё ${Math.max(news.length - 1, 0)} новых</p></div></div></button></div>` : ""}
        <p class="muted">Туннель: ${esc(rt.tunnel)} · ${esc(rt.engineMessage || "")}</p>
      </div>
      <div class="side">
        <div class="card loc-card" style="position:relative">
          <div class="loc-top">${flag(node?.flag)}<div><h3>${esc(node?.name || "Нет конфига")}</h3>
            <div class="online">${node?.until ? `До ${esc(node.until)} · ` : ""}${node?.online === false ? "сервер молчит" : "сервер онлайн"}</div></div>
            ${S.other.showPing ? `<div class="ping">${pingOf(node?.id) == null ? "" : pingOf(node?.id) ? `${pingOf(node.id)} мс` : "—"}</div>` : ""}</div>
          ${S.other.showAutoToggle ? `<div class="row-between" style="margin-top:12px"><div><b>Автонастройка</b> <span class="beta">бета</span></div>${sw("other.autoSetup", S.other.autoSetup)}</div>` : ""}
          <button class="linkish" data-act="pop">Настройки конфига</button>
          ${ui.pop ? `<div class="menu-pop">
            <button data-go-root="configroute">Маршрутизация (сервер)</button>
            <button data-go-root="xray">Xray-конфиг</button>
            <button data-act="toggle-auto">Изменение настроек</button>
          </div>` : ""}
        </div>
        <div class="card loc-card">
          <div class="section-label">Локации <span class="tools"><button class="icon-btn" data-act="refresh" title="Обновить">↻</button><button class="icon-btn" data-act="ping" title="Пинг">⌁</button></span></div>
          ${nodes().filter((n) => n.id !== node?.id).map((n) => `<button class="loc" data-act="pick" data-id="${n.id}">${flag(n.flag)}<span><strong>${esc(n.name)}</strong><small>${n.until ? `До ${esc(n.until)} · ` : ""}${n.online === false ? "нет ответа" : "сервер онлайн"}${S.other.showPing && pingOf(n.id) ? ` · ${pingOf(n.id)} мс` : ""}</small></span></button>`).join("")}
        </div>
      </div>
    </div>
    ${ui.stack.length ? `<div class="drawer-back" data-act="close"></div><aside class="drawer">${(screens[ui.stack.at(-1)] || screenMenu)()}</aside>` : ""}
    ${ui.modal === "new" ? `<div class="drawer-back" data-act="modal-close"></div><div class="modal"><h3>Новое устройство</h3><p class="muted">Оставить через VPN или пустить напрямую. Для случайного MAC отметку придётся ставить заново.</p><button class="primary" data-act="keep-vpn">Оставить через VPN</button><button class="ghost" data-act="let-direct">Пустить напрямую</button></div>` : ""}
    ${ui.toast ? `<div class="toast">${esc(ui.toast)}</div>` : ""}
  </div>`;
}

function bootSplash() {
  return `<div class="login"><div class="login-card">
    <svg class="globe" viewBox="0 0 64 64" fill="none" stroke="currentColor" stroke-width="2"><circle cx="32" cy="32" r="18"/><path d="M14 32h36M32 14c6 6 6 30 0 36M32 14c-6 6-6 30 0 36"/></svg>
    <h1>EngVPN</h1>
    <p>Открываю панель…</p>
    <div class="hint">Панель · порт 8790</div>
  </div></div>`;
}

function loginScreen() {
  const type = ui.showPass ? "text" : "password";
  return `<div class="login"><div class="login-card">
    <svg class="globe" viewBox="0 0 64 64" fill="none" stroke="currentColor" stroke-width="2"><circle cx="32" cy="32" r="18"/><path d="M14 32h36M32 14c6 6 6 30 0 36M32 14c-6 6-6 30 0 36"/></svg>
    <h1>EngVPN</h1>
    <p>Введите пароль панели, заданный при установке на роутер</p>
    <form id="login-form" autocomplete="current-password">
      <div class="field">
        <input id="panel-pass" name="password" type="${type}" placeholder="Пароль панели" autofocus>
        <button type="button" class="eye" data-act="eye" aria-label="Показать пароль">${ui.showPass ? "🙈" : "👁"}</button>
      </div>
      <div class="err">${esc(ui.loginErr || "")}</div>
      <button class="primary" type="submit" ${ui.loginBusy ? "disabled" : ""}>${ui.loginBusy ? "Вхожу…" : "Войти"}</button>
    </form>
  </div></div>`;
}

function render() {
  applyTheme();
  const scroll = document.querySelector(".drawer-body")?.scrollTop || 0;
  if (ui.auth === false) app.innerHTML = loginScreen();
  else if (!S) app.innerHTML = bootSplash();
  else app.innerHTML = home();
  const body = document.querySelector(".drawer-body");
  if (body) body.scrollTop = scroll;
  const q = document.querySelector("#q");
  if (q) q.focus();
  const form = document.querySelector("#login-form");
  if (form) {
    form.addEventListener("submit", (ev) => {
      ev.preventDefault();
      doLogin(document.querySelector("#panel-pass")?.value || "");
    });
  }
}

function paintLive() {
  const rt = S.runtime;
  const load = document.querySelector("[data-live=load]");
  if (load) load.textContent = `ЦП ${rt.load.cpu}% · ОЗУ ${mem(rt.load.ramUsed)}/${mem(rt.load.ramTotal)} · EngVPN ${fmtBytes(rt.load.proc)}`;
  const speed = document.querySelector("[data-live=speed]");
  if (speed) speed.innerHTML = `VPN ↓ ${fmt(rt.rates.vpnDown)} ↑ ${fmt(rt.rates.vpnUp)}<br>Напрямую ↓ ${fmt(rt.rates.directDown)} ↑ ${fmt(rt.rates.directUp)}`;
  const sp = document.querySelector("[data-live=spark]");
  if (sp) sp.innerHTML = spark(rt.history);
}

function open(id) {
  if (!ui.stack.length) ui.stack = ["menu"];
  if (ui.stack.at(-1) !== id) ui.stack.push(id);
  ui.pop = false;
  render();
}

document.addEventListener("click", (event) => {
  const t = event.target.closest("[data-act],[data-go],[data-go-root],[data-toggle],[data-hour],[data-theme],[data-icon],[data-engine],[data-mux],[data-source],[data-geo],[data-copy]");
  if (!t || (!S && t.dataset.act !== "eye" && ui.auth !== false)) return;
  const act = t.dataset.act;
  if (t.dataset.go) { ui.form.id = t.dataset.id || ui.form.id; open(t.dataset.go); return; }
  if (t.dataset.goRoot) { ui.stack = ["menu", t.dataset.goRoot]; ui.pop = false; render(); return; }
  if (t.dataset.toggle) {
    const path = t.dataset.toggle;
    const on = !t.classList.contains("on");
    if (path === "smartdns.enabled") {
      S.smartdns = S.smartdns || { enabled: false, entries: [] };
      S.smartdns.enabled = on;
      run(async () => {
        const text = (S.smartdns.entries || []).join("\n");
        const result = await invoke("smartdns", { action: "apply", enabled: on, text });
        if (result?.entries) S.smartdns = { enabled: !!result.enabled, entries: result.entries };
      });
      return;
    }
    run(() => invoke("patch", { path, value: on }));
    return;
  }
  if (t.dataset.hour != null) {
    const hours = [...S.router.scheduleHours];
    hours[Number(t.dataset.hour)] = !hours[Number(t.dataset.hour)];
    run(() => invoke("patch", { path: "router.scheduleHours", value: hours }));
    return;
  }
  if (t.dataset.theme) return run(() => invoke("patch", { path: "appearance.theme", value: t.dataset.theme }));
  if (t.dataset.icon) return run(() => invoke("patch", { path: "appearance.icon", value: t.dataset.icon }));
  if (t.dataset.engine) return run(() => invoke("patch", { path: "engine.preference", value: t.dataset.engine }));
  if (t.dataset.mux) return run(() => invoke("patch", { path: "connection.mux", value: t.dataset.mux }));
  if (t.dataset.source) return run(() => invoke("setRoutingSource", { source: t.dataset.source }));
  if (t.dataset.geo) return run(() => invoke("patch", { path: "engine.geoSource", value: t.dataset.geo }));
  if (t.dataset.copy != null) { navigator.clipboard?.writeText(t.dataset.copy); toast("Скопировано"); return; }
  if (act === "eye") { ui.showPass = !ui.showPass; render(); return; }
  if (act === "settings") { ui.stack = ["menu"]; render(); return; }
  if (act === "close") { ui.stack = []; ui.pop = false; render(); return; }
  if (act === "back") { ui.stack.pop(); if (!ui.stack.length) ui.stack = ["menu"]; render(); return; }
  if (act === "pop") { ui.pop = !ui.pop; render(); return; }
  if (act === "toggle") return run(async () => {
    ui.busy = true; render();
    try {
      if (S.vpn.connected) await invoke("disconnect");
      else if (S.vpn.directMode) await invoke("selectNode", { id: S.vpn.lastVpnId || nodes().find((n) => n.protocol !== "direct")?.id });
      else await invoke("connect");
    } finally {
      ui.busy = false;
      render();
    }
  });
  if (act === "pick") return run(() => invoke("selectNode", { id: t.dataset.id }));
  if (act === "refresh") return run(async () => {
    if (S.account?.apiKeySet) {
      await invoke("syncAccount", {});
      toast("Конфиги и баланс обновлены из API");
      return;
    }
    await invoke("refreshSubscription", {});
  });
  if (act === "ping") return run(async () => { await invoke("pingAll", {}, { quiet: true }); toast("Пинг обновлён"); });
  if (act === "ip") { const ip = S.runtime.exitIp || S.runtime.publicIp; if (ip) window.open(`https://2ip.io/${ip}`, "_blank"); return; }
  if (act === "toggle-auto") return run(() => invoke("patch", { path: "other.autoSetup", value: !S.other.autoSetup }));
  if (act === "new-devices") { ui.modal = "new"; render(); return; }
  if (act === "modal-close") { ui.modal = null; render(); return; }
  if (act === "keep-vpn") return run(() => { ui.modal = null; return invoke("dismissNew", { keepVpn: true }); });
  if (act === "let-direct") return run(() => { ui.modal = null; return invoke("dismissNew", { keepVpn: false }); });
  if (act === "open-console") { if (S.account.consoleUrl) window.open(S.account.consoleUrl, "_blank"); else toast("Ссылка консоли не задана"); return; }
  if (act === "pair") return run(async () => { ui.result = await invoke("pair", {}, { quiet: true }); render(); });
  if (act === "backup-create") return run(async () => {
    const res = await invoke("engvpnBackup", { action: "create" }, { quiet: true });
    toast(res?.output || "Бэкап создан");
  });
  if (act === "backup-latest") return run(async () => {
    const res = await invoke("engvpnBackup", { action: "latest" }, { quiet: true });
    toast(res?.output || "Нет архивов");
  });
  if (act === "export") return run(async () => {
    const file = await invoke("export", {}, { quiet: true });
    const blob = new Blob([JSON.stringify(file.settings, null, 2)], { type: "application/json" });
    const a = document.createElement("a");
    a.href = URL.createObjectURL(blob); a.download = file.filename; a.click();
  });
  if (act === "add-device") {
    const ip = prompt("IP устройства", "192.168.50.150");
    if (ip) run(() => invoke("deviceSet", { ip, name: ip }));
    return;
  }
  if (act === "scan-devices") return run(async () => {
    await invoke("scanDevices", {});
    toast("Список устройств обновлён");
  });
  if (act === "save-smartdns") return run(async () => {
    const text = document.querySelector("#smartdns-list")?.value || "";
    const enabled = !!(S.smartdns?.enabled);
    const result = await invoke("smartdns", { action: "apply", enabled, text });
    if (result && result.entries) S.smartdns = { enabled: !!result.enabled, entries: result.entries };
    toast("SmartDNS применён");
  });
  if (act === "why") return run(async () => {
    const host = document.querySelector("#why").value.trim();
    ui.result = await invoke("explain", { host, clientIp: t.dataset.ip }, { quiet: true });
    render();
  });
  if (act === "save-ads") return run(() => {
    const id = t.dataset.kind === "adWhitelist" ? "adwhite" : "adcustom";
    const value = document.querySelector(`#${id}`).value.split(/\s+/).filter(Boolean);
    return invoke("patch", { path: `router.${t.dataset.kind}`, value });
  });
  if (act === "wol") return run(async () => { await invoke("wol", { mac: t.dataset.mac }, { quiet: true }); toast("Пакет отправлен"); });
  if (act === "mqtt") return run(async () => { await invoke("mqttTest", {}, { quiet: true }); toast("MQTT опубликован"); });
  if (act === "password") return run(async () => {
    await invoke("setPassword", { oldPassword: document.querySelector("#oldp").value, password: document.querySelector("#newp").value }, { quiet: true });
    S = null; ui.stack = []; toast("Войдите с новым паролем");
  });
  if (act === "refresh-sub") return run(() => invoke("refreshSubscription", { id: S.activeSubscription }));
  if (act === "add-sub") return run(() => invoke("addSubscription", { name: document.querySelector("#subname").value, url: document.querySelector("#suburl").value }));
  if (act === "del-sub") return run(() => invoke("removeSubscription", { id: t.dataset.id }));
  if (act === "apply-routing") return run(() => invoke("applyRouting", {}));
  if (act === "add-rule") return run(() => invoke("addRule", { action: document.querySelector("[data-set=draft-action]").value, conditions: [{ kind: document.querySelector("[data-set=draft-kind]").value, value: document.querySelector("#ruleval").value }] }));
  if (act === "del-rule") return run(() => invoke("deleteRule", { id: t.dataset.id }));
  if (act === "add-bal") return run(() => invoke("saveBalancer", { name: document.querySelector("#balname").value, servers: [...document.querySelectorAll(".bal:checked")].map((n) => n.value) }));
  if (act === "del-bal") return run(() => invoke("deleteBalancer", { id: t.dataset.id }));
  if (act === "use-bal") return run(async () => {
    const bal = S.routing.balancers.find((b) => b.id === t.dataset.id);
    let best = null;
    for (const id of bal.servers) {
      const row = await invoke("ping", { id }, { quiet: true });
      if (row.ms != null && (!best || row.ms < best.ms)) best = row;
    }
    if (!best) throw new Error("Ни один сервер не ответил");
    await invoke("selectNode", { id: best.id });
  });
  if (act === "save-profile") return run(() => invoke("saveProfile", { name: `Профиль ${new Date().toLocaleString()}` }));
  if (act === "apply-profile") return run(() => invoke("applyProfile", { id: t.dataset.id }));
  if (act === "del-profile") return run(() => invoke("deleteProfile", { id: t.dataset.id }));
  if (act === "add-cr") {
    const pack = (S.configRoutes || {})[S.vpn.selectedId] || { rules: [] };
    pack.rules = [...(pack.rules || []), { id: Date.now().toString(36), tag: document.querySelector("[data-set=cr-tag]").value, protocol: document.querySelector("[data-set=cr-proto]").value, domains: [document.querySelector("#crdom").value].filter(Boolean), ips: [] }];
    S.configRoutes = { ...S.configRoutes, [S.vpn.selectedId]: pack };
    render();
    return;
  }
  if (act === "drop-cr") {
    const pack = S.configRoutes[S.vpn.selectedId];
    pack.rules.splice(Number(t.dataset.i), 1);
    render();
    return;
  }
  if (act === "save-cr") return run(() => invoke("saveConfigRoute", { nodeId: S.vpn.selectedId, rules: (S.configRoutes[S.vpn.selectedId] || {}).rules || [] }));
  if (act === "copy-rules") { navigator.clipboard?.writeText(JSON.stringify((S.configRoutes || {})[S.vpn.selectedId] || {}, null, 2)); toast("Скопировано"); return; }
  if (act === "download-rules") {
    const blob = new Blob([JSON.stringify((S.configRoutes || {})[S.vpn.selectedId] || {}, null, 2)], { type: "application/json" });
    const a = document.createElement("a"); a.href = URL.createObjectURL(blob); a.download = "routing.json"; a.click(); return;
  }
  if (act === "import-rules") {
    const text = prompt("JSON правил");
    if (!text) return;
    try { const rules = JSON.parse(text).rules || JSON.parse(text); S.configRoutes[S.vpn.selectedId] = { rules }; render(); }
    catch { toast("Не получилось прочитать JSON"); }
    return;
  }
  if (act === "add-pool") {
    const node = nodes().find((n) => n.protocol !== "direct" && n.id !== S.vpn.selectedId);
    if (!node) return;
    const pack = (S.configRoutes || {})[S.vpn.selectedId] || { rules: [] };
    pack.rules = [...(pack.rules || []), { id: node.id, tag: node.name, protocol: "any", domains: [], ips: [] }];
    S.configRoutes = { ...S.configRoutes, [S.vpn.selectedId]: pack };
    render();
    return;
  }
  if (act === "zapret") return run(() => invoke("zapretRecheck", { all: t.dataset.all === "1" }));
  if (act === "zapret-list") return run(() => invoke("zapretList", { name: document.querySelector("#zname").value, domains: document.querySelector("#zdom").value }));
  if (act === "zapret-method") return run(() => invoke("zapretMethod", { name: document.querySelector("#zmethod").value, kind: document.querySelector("[data-set=zkind]").value }));
  if (act === "zapret-reset") return run(() => invoke("patch", { path: "network.zapret.serviceWays", value: {} }));
  if (act === "save-api-key") return run(async () => {
    const apiKey = document.querySelector("#apikey")?.value || "";
    const result = await invoke("saveAccount", { apiKey });
    const n = result?.nodes ?? S.account?.configsCount;
    const bal = result?.balance ?? S.account?.balance;
    toast(n != null
      ? `Синхронизировано: ${n} конфиг. · баланс ${bal != null ? formatRub(bal) : "—"}`
      : "API-ключ сохранён, конфиги синхронизированы");
  });
  if (act === "save-sub-url") return run(async () => {
    const subscriptionUrl = document.querySelector("#suburl-acc")?.value || "";
    const name = document.querySelector("#subname-acc")?.value || "Подписка по URL";
    await invoke("saveAccount", { subscriptionUrl, name, preferUrl: true });
    toast("URL подписки сохранён");
  });
  if (act === "sync-account") return run(async () => {
    await invoke("syncAccount", {});
    toast("Синхронизация завершена");
  });
  if (act === "clear-api-key") return run(async () => {
    await invoke("clearAccount", {});
    toast("API-ключ удалён");
  });
  if (act === "warp-create") return run(async () => {
    toast("Регистрирую Cloudflare WARP…", 6000);
    await invoke("warpCreate", {});
    toast("Профиль WARP создан");
  });
  if (act === "warp-import") return run(() => invoke("warpImport", { text: document.querySelector("#warpini").value }));
  if (act === "gre-up") return run(() => invoke("engvpnWarp", { action: "gre-up" }));
  if (act === "gre-down") return run(() => invoke("engvpnWarp", { action: "gre-down" }));
  if (act === "add-bridge") return run(() => invoke("addBridge", { to: document.querySelector("[data-set=bridge-to]").value }));
  if (act === "del-bridge") return run(() => invoke("deleteBridge", { id: t.dataset.id }));
  if (act === "automode") return run(() => invoke("automode", {}));
  if (act === "detect-net") return run(() => invoke("detectNetwork", {}));
  if (act === "get-core") return run(async () => {
    const id = t.dataset.id;
    if (ui.busyCore) { toast("Уже скачивается другое ядро…"); return; }
    ui.busyCore = id;
    toast("Скачиваю ядро с GitHub… это может занять минуту", 8000);
    render();
    try {
      await invoke("downloadCore", { id });
      toast("Ядро скачано", 4000);
    } finally {
      ui.busyCore = null;
      render();
    }
  });
  if (act === "del-core") return run(() => invoke("deleteCore", { id: t.dataset.id }));
  if (act === "test-core") return run(async () => {
    const res = await invoke("testCore", { id: t.dataset.id }, { quiet: true });
    toast(res.ok ? "Конфиг ядра принят" : (res.error || res.output || "Ядро не приняло конфиг"));
  });
  if (act === "geo") return run(async () => { toast("Качаю гео-базы…"); await invoke("updateGeo", {}); toast("Гео-базы обновлены"); });
  if (act === "load-config") return run(async () => {
    const configs = await invoke("configs", {}, { quiet: true });
    ui.result = { text: Object.entries(configs).map(([k, v]) => `----- ${k} -----\n${v}`).join("\n\n") };
    render();
  });
  if (act === "check-updates") return run(async () => {
    let res;
    try { res = await invoke("engvpnUpdateCheck", {}, { quiet: true }); }
    catch { res = await invoke("checkUpdates", {}, { quiet: true }); }
    const msg = res.message || (res.version ? `Доступно: ${res.version}` : null) || (res.current ? `Текущая: ${res.current}` : null) || "Проверено";
    toast(typeof msg === "string" ? msg : JSON.stringify(res));
  });
  if (act === "feedback") return run(async () => {
    const files = [];
    for (const file of document.querySelector("#ideafiles").files || []) {
      if (files.length >= 5) break;
      const data = await file.arrayBuffer();
      files.push({ name: file.name, data: btoa(String.fromCharCode(...new Uint8Array(data))) });
    }
    await invoke("feedback", { text: document.querySelector("#idea").value, files });
    toast("Записано локально");
  });
  if (act === "support") { toast("Поддержка в EngVPN не подключена: идея остаётся на этом роутере"); return; }
  if (act === "speedtest") return run(async () => { ui.result = await invoke("speedTest", {}, { quiet: true }); render(); });
  if (act === "leak") return run(async () => { ui.result = await invoke("leakTest", {}, { quiet: true }); render(); });
  if (act === "reset-net") return run(() => invoke("resetNetwork", {}));
  if (act === "clear-logs") return run(() => invoke("clearLogs", {}));
});

document.addEventListener("change", (event) => {
  const t = event.target;
  if (t.dataset.set === "activeSub") return run(() => invoke("setSubscription", { id: t.value }));
  if (t.dataset.set?.startsWith("deviceRoute:")) {
    const id = t.dataset.set.split(":")[1];
    return run(() => invoke("deviceSet", { id, route: t.value }));
  }
  if (t.dataset.set?.startsWith("deviceConfig:")) {
    const id = t.dataset.set.split(":")[1];
    return run(() => invoke("deviceSet", { id, route: "config", configId: t.value }));
  }
  if (t.dataset.set && !t.dataset.set.startsWith("draft") && !t.dataset.set.startsWith("cr-") && t.dataset.set !== "bridge-to" && t.dataset.set !== "zkind") {
    let value = t.value;
    if (value === "true") value = true;
    if (value === "false") value = false;
    return run(() => invoke("patch", { path: t.dataset.set, value }));
  }
  if (t.dataset.device) return run(() => invoke("deviceSet", { id: t.dataset.device, excluded: t.checked }));
  if (t.dataset.adex) {
    const set = new Set(S.router.adExcludeDevices || []);
    if (t.checked) set.add(t.dataset.adex); else set.delete(t.dataset.adex);
    return run(() => invoke("patch", { path: "router.adExcludeDevices", value: [...set] }));
  }
  if (t.dataset.act === "import") {
    const file = t.files?.[0];
    if (!file) return;
    file.text().then((text) => run(() => invoke("import", { settings: JSON.parse(text) })));
  }
});
document.addEventListener("input", (event) => {
  if (event.target.id === "q" || event.target.dataset.local) {
    if (event.target.id === "q") ui.query = event.target.value;
    else ui.form[event.target.dataset.local] = event.target.value;
    const y = document.querySelector(".drawer-body")?.scrollTop || 0;
    const pos = event.target.selectionStart;
    render();
    const body = document.querySelector(".drawer-body");
    if (body) body.scrollTop = y;
    const again = document.getElementById(event.target.id);
    if (again) { again.focus(); if (pos != null) again.setSelectionRange(pos, pos); }
  }
});
document.addEventListener("change", (event) => {
  const path = event.target.dataset.input || event.target.dataset.set;
  if (path) {
    let value = event.target.value;
    if (/port|Concurrency|window/.test(path)) value = Number(value);
    run(() => invoke("patch", { path, value }));
  }
  if (event.target.dataset.rename) run(() => invoke("deviceRename", { id: event.target.dataset.rename, name: event.target.value }));
  if (event.target.dataset.local) ui.form[event.target.dataset.local] = event.target.value;
});
function listen() {
  if (es) es.close();
  es = new EventSource("/api/events");
  es.onmessage = (ev) => {
    const msg = JSON.parse(ev.data);
    if (!S) return;
    if (msg.type === "tick") {
      S.runtime = msg.runtime;
      S.vpn.connected = msg.connected;
      S.vpn.directMode = msg.directMode;
      paintLive();
    } else if (msg.type === "snapshot") {
      S = msg.state;
      if (!ui.stack.length) render();
    } else if (msg.type === "log" && ui.stack.at(-1) === "logs") {
      S.logs.unshift(msg);
      render();
    }
  };
}

async function afterAuth() {
  S = await api("/api/snapshot");
  ui.auth = true;
  ui.toast = "";
  listen();
  render();
}

async function doLogin(password) {
  ui.loginBusy = true;
  ui.loginErr = "";
  render();
  try {
    await api("/api/login", { password: String(password || "").trim() });
    await afterAuth();
  } catch (err) {
    ui.loginErr = err.message || "Неверный пароль";
    ui.loginBusy = false;
    ui.auth = false;
    render();
  }
}

async function openPanel() {
  render();
  const session = await api("/api/session");
  if (session.authenticated || session.openAccess) {
    await afterAuth();
    return;
  }
  ui.auth = false;
  render();
}

openPanel().catch((err) => {
  ui.auth = false;
  ui.loginErr = err.message || "Не удалось открыть панель";
  render();
});
