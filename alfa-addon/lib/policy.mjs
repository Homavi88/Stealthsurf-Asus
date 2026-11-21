import {
  ADS_SUFFIXES,
  ANDROID_AUTO_SUFFIXES,
  DISCORD_SUFFIXES,
  DOH_HOSTS,
  GAME_SUFFIXES,
  GEOSITE,
  PORN_SUFFIXES,
  PRIVATE_CIDRS,
  RU_WHITELIST,
  SPOTIFY_SUFFIXES,
  TELEGRAM_SUFFIXES,
  TWITCH_SUFFIXES,
  YOUTUBE_SUFFIXES,
  hostMatches,
  isIpv4,
  isIpv6,
  isRuHost,
} from "./catalog.mjs";

function cidrMatch(ip, cidr) {
  if (!ip || !cidr) return false;
  if (cidr.includes(":") || ip.includes(":")) {
    if (cidr === "::1/128") return ip === "::1" || ip === "::1";
    return false;
  }
  const [base, bitsRaw] = cidr.split("/");
  const bits = Number(bitsRaw);
  if (!isIpv4(ip) || !isIpv4(base) || Number.isNaN(bits)) return false;
  const toInt = (value) => value.split(".").reduce((acc, part) => (acc << 8) + Number(part), 0) >>> 0;
  if (bits === 0) return true;
  const mask = bits === 32 ? 0xffffffff : (~((1 << (32 - bits)) - 1)) >>> 0;
  return (toInt(ip) & mask) === (toInt(base) & mask);
}

function inAnyCidr(ip, cidrs) {
  return cidrs.some((cidr) => cidrMatch(ip, cidr));
}

export function deviceFor(state, clientIp) {
  const ip = normalizeIp(clientIp);
  return state.devices.find((d) => d.ip === ip) || null;
}

export function normalizeIp(ip) {
  const raw = String(ip || "").replace(/^::ffff:/, "");
  return raw;
}

function wantsVpn(state, device) {
  const mode = state.router.mode;
  if (state.vpn.directMode || !state.vpn.connected) return false;
  if (mode === "off") return false;
  if (!device) return mode === "all" || mode === "except";
  if (device.route === "direct") return false;
  if (mode === "all") return true;
  if (mode === "selected") return Boolean(device.excluded);
  if (mode === "except") return !device.excluded;
  return true;
}

function portIn(port, from, to) {
  return port >= from && port <= to;
}

function domainRuleHit(host, value) {
  const raw = String(value || "").trim();
  if (!raw) return false;
  const neg = raw.startsWith("!");
  const body = neg ? raw.slice(1) : raw;
  let hit = false;
  if (body.startsWith("domain:")) hit = hostMatches(host, [body.slice(7)]);
  else if (body.startsWith("full:")) hit = host.toLowerCase() === body.slice(5).toLowerCase();
  else if (body.startsWith("keyword:")) hit = host.toLowerCase().includes(body.slice(8).toLowerCase());
  else if (body.startsWith("geosite:")) {
    const name = body.slice(8);
    const list = GEOSITE[name] || [];
    if (name === "category-ru") hit = isRuHost(host);
    else hit = hostMatches(host, list);
  } else if (body.startsWith("regexp:")) {
    try { hit = new RegExp(body.slice(7), "i").test(host); } catch { hit = false; }
  } else hit = hostMatches(host, [body]);
  return neg ? !hit : hit;
}

function ipRuleHit(host, value) {
  const raw = String(value || "").trim();
  if (!raw) return false;
  const neg = raw.startsWith("!");
  const body = neg ? raw.slice(1) : raw;
  let hit = false;
  if (body.startsWith("geoip:")) {
    const name = body.slice(6);
    if (name === "private") hit = inAnyCidr(host, PRIVATE_CIDRS);
    else hit = false;
  } else if (body.includes("/")) hit = cidrMatch(host, body);
  else hit = host === body;
  return neg ? !hit : hit;
}

/**
 * First matching rule wins. The same list is compiled into Xray, sing-box and mihomo.
 */
export function ruleList(state) {
  const rules = [];
  const push = (rule) => rules.push(rule);

  if (state.router.trips && state.router.captive) {
    push({ id: "captive", action: "direct", reason: "Портал сети открыт, устройства идут напрямую", match: { any: true } });
  }

  if (state.router.ipv6 === "block") {
    push({ id: "ipv6-block", action: "block", reason: "IPv6 устройств блокируется", match: { ipv6: true } });
  } else if (state.router.ipv6 === "direct") {
    push({ id: "ipv6-direct", action: "direct", reason: "IPv6 устройств идёт напрямую", match: { ipv6: true } });
  }

  if (state.router.blockQuic || state.routing.blockQuic) {
    push({ id: "quic", action: "block", reason: "QUIC заблокирован, нужен TCP", match: { network: "udp", port: 443 } });
  }

  if (state.routing.lan) {
    push({ id: "lan", action: "direct", reason: "Локальная сеть напрямую", match: { cidrs: PRIVATE_CIDRS } });
  }

  if (state.router.dnsLock) {
    push({ id: "doh", action: "block", reason: "Обход DNS роутера закрыт", match: { suffixes: DOH_HOSTS } });
  }

  const adOn = state.router.adblock || state.routing.blockAds;
  if (adOn) {
    push({
      id: "ads",
      action: "block",
      reason: "Рекламный домен",
      match: { suffixes: [...ADS_SUFFIXES, ...state.router.adCustom] },
      skipDevices: state.router.adExcludeDevices,
      allow: state.router.adWhitelist,
    });
  }

  if (state.routing.blockPorn) {
    push({ id: "porn", action: "block", reason: "Домен из списка взрослых сайтов", match: { suffixes: PORN_SUFFIXES } });
  }

  for (const rule of state.routing.custom || []) {
    push({
      id: `custom-${rule.id}`,
      action: rule.action || "direct",
      reason: rule.note || "Пользовательское правило",
      match: { custom: rule },
    });
  }

  const selected = state.configRoutes?.[state.vpn.selectedId];
  for (const rule of selected?.rules || []) {
    push({
      id: `cfg-${rule.id}`,
      action: tagToAction(rule.tag),
      reason: `Правило конфига: ${rule.tag}`,
      tag: rule.tag,
      match: { configRule: rule },
    });
  }

  if (state.network.telegramDirect) {
    push({ id: "telegram", action: "direct", reason: "Telegram напрямую", match: { suffixes: TELEGRAM_SUFFIXES } });
  }
  if (state.network.youtubeZapret && state.network.zapret.serviceWays.youtube !== "vpn") {
    push({ id: "youtube", action: "direct", reason: "YouTube через прямой путь, запасной — VPN", match: { suffixes: YOUTUBE_SUFFIXES } });
  }
  if (state.network.discordZapret && state.network.zapret.serviceWays.discord !== "vpn") {
    push({ id: "discord", action: "direct", reason: "Discord через прямой путь, запасной — VPN", match: { suffixes: DISCORD_SUFFIXES } });
  }
  for (const list of state.network.zapret.lists || []) {
    if (!list.enabled) continue;
    const way = state.network.zapret.serviceWays[list.id];
    push({
      id: `zapret-${list.id}`,
      action: way === "vpn" ? "proxy" : "direct",
      reason: `Свой список «${list.name}»`,
      match: { suffixes: list.domains || [] },
    });
  }

  if (state.routing.excludeRu) {
    push({ id: "ru", action: "direct", reason: "Российская зона напрямую", match: { ru: true } });
  }
  if (state.routing.whitelist) {
    push({ id: "whitelist", action: "direct", reason: "Сервис из белого списка напрямую", match: { suffixes: RU_WHITELIST } });
  }
  if (state.routing.twitch) push({ id: "twitch", action: "direct", reason: "Twitch напрямую", match: { suffixes: TWITCH_SUFFIXES } });
  if (state.routing.spotify) push({ id: "spotify", action: "direct", reason: "Spotify напрямую", match: { suffixes: SPOTIFY_SUFFIXES } });
  if (state.routing.androidAuto) {
    push({ id: "android-auto", action: "direct", reason: "Android Auto напрямую", match: { suffixes: ANDROID_AUTO_SUFFIXES } });
  }
  if (state.routing.bittorrent) {
    push({ id: "bittorrent", action: "direct", reason: "BitTorrent напрямую", match: { ports: [[6881, 6999], [51413, 51413]], protocol: "bittorrent" } });
  }
  if (state.routing.games || state.router.gamesDirect) {
    push({ id: "games", action: "direct", reason: "Загрузка игр напрямую", match: { suffixes: GAME_SUFFIXES } });
  }

  for (const device of state.devices) {
    if (device.route === "config" && device.configId) {
      push({
        id: `dev-route-${device.id}`,
        action: "proxy",
        reason: `Свой конфиг устройства ${device.name}`,
        tag: device.configId,
        match: { clientIps: [device.ip] },
      });
    }
    if (device.bypass?.length) {
      push({
        id: `dev-bypass-${device.id}`,
        action: "direct",
        reason: `Сайты мимо VPN для ${device.name}`,
        match: { clientIps: [device.ip], suffixes: device.bypass },
      });
    }
  }

  return rules;
}

function tagToAction(tag) {
  const value = String(tag || "").toLowerCase();
  if (value === "direct" || value === "напрямую") return "direct";
  if (value === "block" || value === "забанить" || value === "ban") return "block";
  return "proxy";
}

function matches(rule, req, device) {
  if (rule.skipDevices?.includes(device?.id)) return false;
  if (rule.allow?.length && hostMatches(req.host, rule.allow)) return false;
  const match = rule.match || {};
  if (match.any) return true;
  if (match.clientIps && !match.clientIps.includes(normalizeIp(req.clientIp))) return false;
  if (match.ipv6 && !isIpv6(req.host)) return false;
  if (match.network && match.network !== (req.network || "tcp")) return false;
  if (match.port && Number(req.port) !== Number(match.port)) return false;
  if (match.ports && !match.ports.some(([a, b]) => portIn(Number(req.port), a, b)) && req.protocol !== match.protocol) {
    return false;
  }
  if (match.protocol && !match.ports && req.protocol !== match.protocol) return false;
  if (match.ru && !isRuHost(req.host)) return false;
  if (match.suffixes && !hostMatches(req.host, match.suffixes)) return false;
  if (match.cidrs && !inAnyCidr(req.host, match.cidrs)) return false;
  if (match.custom) {
    const conds = match.custom.conditions || [];
    if (!conds.length) return false;
    return conds.every((cond) => matchCondition(cond, req));
  }
  if (match.configRule) {
    const rule = match.configRule;
    if (rule.protocol && rule.protocol !== "any" && rule.protocol !== req.protocol && !protocolPort(rule.protocol, req)) {
      return false;
    }
    const domains = rule.domains || [];
    const ips = rule.ips || [];
    if (!domains.length && !ips.length && !rule.protocol) return false;
    const domainOk = domains.length ? domains.some((item) => domainRuleHit(req.host, item)) : true;
    const ipOk = ips.length ? ips.some((item) => ipRuleHit(req.host, item)) : true;
    return domainOk && ipOk;
  }
  return true;
}

function protocolPort(protocol, req) {
  if (protocol === "bittorrent") return portIn(Number(req.port), 6881, 6999) || Number(req.port) === 51413;
  return false;
}

function matchCondition(cond, req) {
  const kind = cond.kind;
  const value = cond.value;
  if (kind === "domain" || kind === "geosite") return domainRuleHit(req.host, kind === "geosite" ? `geosite:${value}` : value);
  if (kind === "ip" || kind === "cidr" || kind === "geoip") {
    const expr = kind === "geoip" ? `geoip:${value}` : value;
    return ipRuleHit(req.host, expr);
  }
  if (kind === "protocol") return req.protocol === value || protocolPort(value, req);
  if (kind === "port") return Number(req.port) === Number(value);
  return false;
}

export function evaluate(state, req) {
  const host = String(req.host || "").toLowerCase();
  const device = deviceFor(state, req.clientIp);
  const query = { ...req, host, network: req.network || "tcp" };

  if (!state.vpn.connected && state.router.blockWithoutVpn && !state.router.captive) {
    const local = inAnyCidr(host, PRIVATE_CIDRS);
    if (!local) {
      return { action: "block", reason: "Интернет без VPN закрыт", device, engineTag: null };
    }
  }

  for (const rule of ruleList(state)) {
    if (matches(rule, query, device)) {
      return { action: rule.action, reason: rule.reason, tag: rule.tag || null, device, ruleId: rule.id };
    }
  }

  const vpn = wantsVpn(state, device);
  if (!vpn) {
    const why = !state.vpn.connected
      ? "VPN выключен"
      : state.vpn.directMode
        ? "Выбран режим без VPN"
        : state.router.mode === "off"
          ? "VPN для сети выключен"
          : device?.excluded && state.router.mode === "except"
            ? "Устройство в исключениях"
            : device?.route === "direct"
              ? "У устройства свой прямой маршрут"
              : "Устройство не входит в выбранные";
    return { action: "direct", reason: why, device, ruleId: "device-mode" };
  }
  return { action: "proxy", reason: "Основной туннель", device, ruleId: "default-proxy" };
}

export function dnsServers(state) {
  const table = {
    cloudflare: ["1.1.1.1", "1.0.0.1"],
    google: ["8.8.8.8", "8.8.4.4"],
    quad9: ["9.9.9.9", "149.112.112.112"],
    adguard: ["94.140.14.14", "94.140.15.15"],
  };
  return {
    primary: table[state.routing.dnsProvider] || table.cloudflare,
    fallback: table[state.routing.dnsFallback] || table.google,
  };
}
