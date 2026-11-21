import engine from '@/modules/Engine';

export interface SurfGateReleaseInfo {
  latest: string;
  current: string;
  updateAvailable: boolean;
}

const DEFAULT_MIRRORS = ['https://gh-proxy.com/', 'https://cdn.gh-proxy.org/', 'https://ghfast.top/', 'https://gitproxy.click/', 'https://github.moeyy.xyz/'];

function normalizeVersion(v?: string | null): string {
  const raw = String(v || '')
    .trim()
    .replace(/^v/i, '');
  if (!raw) return '';
  const parts = raw.split('.');
  if (parts.length === 2) return `${raw}.0`;
  return raw;
}

/** Compare dotted versions: 1 if a>b, 0 equal, -1 if a<b */
export function compareVersions(a: string, b: string): number {
  const pa = normalizeVersion(a)
    .split('.')
    .map((x) => parseInt(x.replace(/\D.*/, ''), 10) || 0);
  const pb = normalizeVersion(b)
    .split('.')
    .map((x) => parseInt(x.replace(/\D.*/, ''), 10) || 0);
  const n = Math.max(pa.length, pb.length, 3);
  for (let i = 0; i < n; i++) {
    const x = pa[i] || 0;
    const y = pb[i] || 0;
    if (x > y) return 1;
    if (x < y) return -1;
  }
  return 0;
}

/**
 * Installed addon version for update banners.
 * Prefer live script `ui_version` over cached `custom_settings.stealthsurf_version`
 * — the NVRAM/file cache can lag after install and keep showing a false "update available".
 * When both exist, use the higher of the two so a stale low cache cannot force a banner.
 */
export function installedVersion(uiVersion?: string): string {
  const fromUi = normalizeVersion(uiVersion || '');
  const fromSettings = normalizeVersion(window.xray?.custom_settings?.stealthsurf_version || '');
  if (fromUi && fromSettings) {
    return compareVersions(fromUi, fromSettings) >= 0 ? fromUi : fromSettings;
  }
  return fromUi || fromSettings || '';
}

/** Keep window.xray.custom_settings in sync with the live script version when it is newer/equal. */
export function syncDisplayedVersion(uiVersion?: string): string {
  const current = installedVersion(uiVersion);
  if (current && window.xray?.custom_settings) {
    const cached = normalizeVersion(window.xray.custom_settings.stealthsurf_version || '');
    if (!cached || compareVersions(current, cached) === 1 || current !== cached) {
      window.xray.custom_settings.stealthsurf_version = current;
    }
  }
  return current;
}

function candidateUrls(url: string, proxy?: string | null): string[] {
  const out: string[] = [];
  const push = (u: string) => {
    if (u && !out.includes(u)) out.push(u);
  };
  const proxied = engine.githubProxyUrl(url, proxy);
  push(proxied);
  push(url);
  for (const m of DEFAULT_MIRRORS) push(`${m}${url}`);
  return out;
}

/**
 * Resolve latest stable SurfGate release from GitHub (browser-side).
 * Tries user proxy, direct, then public mirrors — routers in RU often block api.github.com.
 */
export async function fetchLatestRelease(proxy?: string | null): Promise<string> {
  const api = 'https://api.github.com/repos/Homavi88/Stealthsurf-Asus/releases/latest';
  const listApi = 'https://api.github.com/repos/Homavi88/Stealthsurf-Asus/releases?per_page=10';
  const urls = [...candidateUrls(api, proxy), ...candidateUrls(listApi, proxy)];
  let lastErr: unknown;

  for (const u of urls) {
    try {
      const r = await fetch(u, { cache: 'no-store' });
      if (!r.ok) continue;
      const data = await r.json();
      if (Array.isArray(data)) {
        const stable = data.find((x) => x && !x.draft && !x.prerelease && x.tag_name);
        if (stable?.tag_name) return normalizeVersion(String(stable.tag_name));
        continue;
      }
      if (data?.tag_name && data.prerelease !== true) return normalizeVersion(String(data.tag_name));
      if (data?.tag_name) return normalizeVersion(String(data.tag_name));
    } catch (e) {
      lastErr = e;
    }
  }
  throw lastErr || new Error('GitHub releases unreachable');
}

export async function checkSurfGateUpdate(uiVersion?: string, proxy?: string | null): Promise<SurfGateReleaseInfo> {
  const current = installedVersion(uiVersion);
  const latest = await fetchLatestRelease(proxy);
  return {
    latest,
    current: current || '—',
    updateAvailable: !!current && !!latest && compareVersions(latest, current) === 1
  };
}
