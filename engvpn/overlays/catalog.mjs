/** Domain lists and engine capability matrix used by the live policy and by config compilers. */

export const VERSION = "0.5.30";
export const PANEL_PORT = Number(process.env.ENGVPN_PORT || 8790);
/** Installer sets a panel password; open LAN access only if ENGVPN_OPEN_PANEL=1. */
export const OPEN_PANEL = process.env.ENGVPN_OPEN_PANEL === "1";

export const ENGINES = {
  auto: {
    id: "auto",
    title: "Авто",
    blurb: "Каждый конфиг получает ядро, которое умеет его протокол.",
  },
  xray: {
    id: "xray",
    title: "Xray",
    repo: "XTLS/Xray-core",
    assetHint: "Xray-linux-64.zip",
    bin: "xray",
    ref: "v26.11.9",
    protocols: ["vless", "vmess", "trojan", "shadowsocks", "socks", "http", "direct"],
    routing: "Полная маршрутизация из подписки. Без WireGuard и AmneziaWG.",
    config: "xray",
  },
  ferrum: {
    id: "ferrum",
    title: "Ferrum (Xray Reality)",
    // Open equivalent: same Xray-core binary under the Ferrum slot (Reality / VLESS).
    // Proprietary StealthSurf Ferrum is NOT downloaded.
    repo: "XTLS/Xray-core",
    assetHint: "Xray-linux-64.zip",
    bin: "ferrum",
    ref: "open-xray-reality (XTLS/Xray-core)",
    protocols: ["vless", "vmess", "trojan", "shadowsocks", "socks", "http", "direct"],
    routing: "Открытый слот Ferrum: скачивает Xray-core и принимает тот же JSON (Reality).",
    config: "xray",
  },
  "sing-box": {
    id: "sing-box",
    title: "sing-box",
    repo: "SagerNet/sing-box",
    bin: "sing-box",
    ref: "v1.14.4",
    protocols: ["vless", "vmess", "trojan", "shadowsocks", "hysteria2", "tuic", "wireguard", "socks", "http", "direct"],
    routing: "Конвертация правил. Без AmneziaWG.",
    config: "sing-box",
  },
  mihomo: {
    id: "mihomo",
    title: "mihomo",
    repo: "MetaCubeX/mihomo",
    bin: "mihomo",
    ref: "v1.19.34",
    protocols: ["vless", "vmess", "trojan", "shadowsocks", "hysteria2", "tuic", "wireguard", "amneziawg", "socks", "http", "direct"],
    routing: "Конвертация правил Clash Meta. Поддерживает все протоколы, включая AmneziaWG.",
    config: "mihomo",
  },
};

export const DOH_HOSTS = [
  "dns.google",
  "dns.google.com",
  "cloudflare-dns.com",
  "mozilla.cloudflare-dns.com",
  "dns.quad9.net",
  "doh.opendns.com",
  "dns.adguard-dns.com",
  "common.dot.dns.yandex.net",
  "dns.yandex.ru",
  "doh.dns.apple.com",
  "mask.icloud.com",
  "mask-h2.icloud.com",
];

export const TELEGRAM_SUFFIXES = ["telegram.org", "t.me", "tdesktop.com", "telegra.ph"];
export const YOUTUBE_SUFFIXES = ["youtube.com", "googlevideo.com", "ytimg.com", "youtu.be", "youtubei.googleapis.com"];
export const DISCORD_SUFFIXES = ["discord.com", "discord.gg", "discordapp.com", "discord.media", "discordapp.net"];
export const TWITCH_SUFFIXES = ["twitch.tv", "ttvnw.net", "jtvnw.net"];
export const SPOTIFY_SUFFIXES = ["spotify.com", "scdn.co", "spotifycdn.com"];
export const ANDROID_AUTO_SUFFIXES = ["android.clients.google.com", "connectivitycheck.gstatic.com"];
export const GAME_SUFFIXES = [
  "steampowered.com",
  "steamserver.net",
  "steamcontent.com",
  "epicgames.com",
  "unrealengine.com",
  "akamaihd.net",
  "playstation.net",
  "xboxlive.com",
];
export const ADS_SUFFIXES = [
  "doubleclick.net",
  "googlesyndication.com",
  "googleadservices.com",
  "adservice.google.com",
  "ads.youtube.com",
  "appmetrica.yandex.net",
  "ads.yandex.ru",
  "an.yandex.ru",
  "mc.yandex.ru",
  "yabs.yandex.ru",
  "adfox.ru",
  "ads.example.test",
];
export const PORN_SUFFIXES = ["pornhub.com", "xvideos.com", "xnxx.com", "xhamster.com"];
export const RU_WHITELIST = [
  "gosuslugi.ru",
  "nalog.ru",
  "mos.ru",
  "sberbank.ru",
  "online.sberbank.ru",
  "tinkoff.ru",
  "tbank.ru",
  "vtb.ru",
  "alfabank.ru",
  "vk.com",
  "vk.ru",
  "ok.ru",
  "yandex.ru",
  "ya.ru",
  "yandex.net",
  "avito.ru",
  "ozon.ru",
  "wildberries.ru",
  "market.yandex.ru",
  "ria.ru",
  "rbc.ru",
  "lenta.ru",
];

export const GEOSITE = {
  "category-ru": ["ru", "su", "рф"],
  youtube: YOUTUBE_SUFFIXES,
  telegram: TELEGRAM_SUFFIXES,
  discord: DISCORD_SUFFIXES,
  ads: ADS_SUFFIXES,
  twitch: TWITCH_SUFFIXES,
  spotify: SPOTIFY_SUFFIXES,
  steam: GAME_SUFFIXES,
  bittorrent: [],
  porn: PORN_SUFFIXES,
};

export const PRIVATE_CIDRS = [
  "10.0.0.0/8",
  "172.16.0.0/12",
  "192.168.0.0/16",
  "127.0.0.0/8",
  "169.254.0.0/16",
  "::1/128",
  "fc00::/7",
  "fe80::/10",
];

export function engineSupports(engineId, protocol) {
  if (protocol === "direct") return true;
  const engine = ENGINES[engineId];
  if (!engine || engineId === "auto") return true;
  return engine.protocols.includes(protocol);
}

export function pickEngine(preference, protocol) {
  if (protocol === "direct") return "xray";
  if (preference && preference !== "auto") return preference;
  if (protocol === "amneziawg") return "mihomo";
  if (protocol === "wireguard" || protocol === "hysteria2" || protocol === "tuic") return "sing-box";
  return "xray";
}

export function hostMatches(host, suffixes) {
  const h = String(host || "").toLowerCase().replace(/\.$/, "");
  if (!h) return false;
  return suffixes.some((s) => {
    const x = s.toLowerCase();
    return h === x || h.endsWith(`.${x}`);
  });
}

export function isRuHost(host) {
  const h = String(host || "").toLowerCase();
  return h.endsWith(".ru") || h.endsWith(".su") || h.endsWith(".рф") || h.endsWith(".xn--p1ai");
}

export function isIpv4(host) {
  return /^\d{1,3}(\.\d{1,3}){3}$/.test(host || "");
}

export function isIpv6(host) {
  return String(host || "").includes(":");
}
