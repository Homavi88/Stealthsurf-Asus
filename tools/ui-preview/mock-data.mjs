export const state = {
  active_config_id: 101,
  mode: "redirect",
  proxy_mode: "redirect",
  dns_mode: "OFF",
  default_outbound: "ss-101",
  enabled_outbounds: [101, 205],
  running: true,
  socks_port: 10808,
  http_port: 10809,
  tproxy_port: 10810,
  redirect_port: 10811,
  version: "1.0.18",
  xrayui: { installed: true, running: false, conflict: null, message: null },
  conflict: null,
  conflict_message: null,
};

export const stateConflict = {
  ...state,
  running: false,
  xrayui: {
    installed: true,
    running: true,
    conflict: "xrayui",
    message:
      "XrayUI сейчас работает. Остановите XrayUI (VPN → XrayUI → Stop), затем запускайте StealthSurf. Одновременно оба аддона нельзя.",
  },
  conflict: "xrayui",
  conflict_message:
    "XrayUI сейчас работает. Остановите XrayUI (VPN → XrayUI → Stop), затем запускайте StealthSurf. Одновременно оба аддона нельзя.",
};

export const configs = [
  {
    id: 101,
    name: "NL Amsterdam · VLESS",
    protocol: "vless",
    location: "Netherlands",
    online: true,
    expires_at: "2027-01-15",
  },
  {
    id: 205,
    name: "DE Frankfurt · Hysteria2",
    protocol: "hysteria2",
    location: "Germany",
    online: true,
    expires_at: "2027-01-15",
  },
  {
    id: 312,
    name: "FI Helsinki · Trojan",
    protocol: "trojan",
    location: "Finland",
    online: false,
    expires_at: "2026-12-01",
  },
];

export const locations = [
  { id: "nl", name: "Netherlands" },
  { id: "de", name: "Germany" },
  { id: "fi", name: "Finland" },
];

export const subscriptions = [
  { id: 1, name: "Home pack", status: "active" },
  { id: 2, name: "Travel", status: "paused" },
];

export const api_keys = [
  { label: "main", key: "stlth_abcd1234_xxxxxxxxxxxxxxxxxxxx", tail: "…xxxx" },
];

export const outbounds = { enabled: [101, 205], default: "ss-101" };

/** Example rules for GitHub screenshots of the rule builder */
export const routing = {
  domainStrategy: "AsIs",
  default_outbound: "ss-101",
  preset: "",
  rules: [
    {
      name: "ads",
      type: "geosite",
      matcher: "category-ads-all",
      outbound: "block",
      priority: 5,
    },
    {
      name: "private",
      type: "geoip",
      matcher: "private",
      outbound: "direct",
      priority: 10,
    },
    {
      name: "ru-direct",
      type: "geoip",
      matcher: "ru",
      outbound: "direct",
      priority: 20,
    },
    {
      name: "youtube",
      type: "geosite",
      matcher: "youtube",
      outbound: "ss-101",
      priority: 30,
    },
    {
      name: "telegram",
      type: "domain",
      matcher: "telegram.org",
      outbound: "ss-101",
      priority: 40,
    },
    {
      name: "netflix",
      type: "geosite",
      matcher: "netflix",
      outbound: "ss-205",
      priority: 50,
    },
    {
      name: "openai",
      type: "domain",
      matcher: "openai.com",
      outbound: "ss-101",
      priority: 60,
    },
  ],
};

export const policies = {
  catchall: true,
  rules: [{ mac: "AA:BB:CC:DD:EE:01", mode: "bypass", name: "Notebook" }],
};

export const version = {
  installed: "1.0.18",
  latest: "1.0.18",
  update_available: false,
  tag: "v1.0.18",
};

export const protocols = {
  vless: { runtime: "xray", supported: true, status: "ready" },
  hysteria2: { runtime: "hysteria", supported: true, status: "ready" },
  trojan: { runtime: "xray", supported: true, status: "ready" },
};

export const response = {
  status: true,
  message: "ok",
  data: {},
  ts: Math.floor(Date.now() / 1000),
};
