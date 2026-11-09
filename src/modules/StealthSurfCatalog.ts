export type SsCatalogSource = 'config' | 'paid_option' | 'cloud' | string;

export interface SsLocation {
  id: number | string;
  code?: string | null;
  title?: string | null;
  caption?: string | null;
  description?: string | null;
  is_active?: boolean;
}

export interface SsCatalogConfig {
  id: number | string;
  title?: string;
  name?: string;
  protocol?: string;
  is_online?: boolean;
  connection_url?: string;
  location_id?: number | string;
  server_id?: number | string;
  expires_at?: number;
  created_at?: number;
  auto_renewal?: boolean;
  auto_renewal_days?: number | null;
  ipv6?: string | null;
  flags?: string[];
  _ss_source?: SsCatalogSource;
  _ss_tag?: string;
  _ss_parent_id?: number | string | null;
  _ss_instance_id?: number | string | null;
  _ss_location_title?: string | null;
  _ss_location_code?: string | null;
  _ss_catalog_key?: string;
}

export const SS_DEFAULT_RULE = 'stealthsurf-default';

export const SS_PROTOCOLS = [
  'vless',
  'trojan',
  'trojan-2901',
  'hysteria2',
  'vless-2410',
  'shadowsocks-2022',
  'wg',
  'amnezia-wg-2',
  'openflux'
] as const;

/** Match ss-123 / ss-po-456 / ss-cs-789 / ss-po-wi-4-0 */
export const ssIdFromTag = (tag?: string): string | undefined => {
  if (!tag) return undefined;
  const m = tag.match(/^ss-(?:po-(?:wi-\d+-)?|cs-)?(\d+)$/);
  return m?.[1];
};

export const catalogTag = (c: SsCatalogConfig): string => c._ss_tag || `ss-${c.id}`;

export const catalogTitle = (c: SsCatalogConfig): string => c.title || c.name || catalogTag(c);

export const catalogSourceLabel = (c: SsCatalogConfig): string => {
  switch (c._ss_source || 'config') {
    case 'paid_option':
      return 'paid';
    case 'cloud':
      return 'cloud';
    default:
      return 'vpn';
  }
};

export const locationDisplayName = (loc?: SsLocation | null): string => {
  if (!loc) return '';
  const title = (loc.title || loc.caption || '').trim();
  const code = (loc.code || '').trim();
  if (title && code && title.toLowerCase() !== code.toLowerCase()) return `${title} (${code})`;
  return title || code || '';
};

export const findLocation = (locations: SsLocation[], locationId?: number | string | null): SsLocation | undefined => {
  if (locationId == null || locationId === '') return undefined;
  const key = String(locationId);
  return locations.find((l) => String(l.id) === key);
};

/** Prefer enriched title, then locations map; never show bare numeric id when a name exists. */
export const catalogLocationLabel = (c: SsCatalogConfig, locations: SsLocation[] = []): string => {
  const stamped = (c._ss_location_title || '').trim();
  const code = (c._ss_location_code || '').trim();
  if (stamped) {
    if (code && stamped.toLowerCase() !== code.toLowerCase() && !stamped.includes(`(${code})`)) {
      return `${stamped} (${code})`;
    }
    return stamped;
  }
  const hit = findLocation(locations, c.location_id);
  const named = locationDisplayName(hit);
  if (named) return named;
  if (c.location_id == null || c.location_id === '') return '—';
  return `loc ${c.location_id}`;
};

export const enrichCatalogWithLocations = (configs: SsCatalogConfig[], locations: SsLocation[]): SsCatalogConfig[] =>
  configs.map((c) => {
    const hit = findLocation(locations, c.location_id);
    if (!hit) return c;
    return {
      ...c,
      _ss_location_title: hit.title || hit.caption || hit.code || c._ss_location_title || null,
      _ss_location_code: hit.code || c._ss_location_code || null
    };
  });

export const formatExpiresAt = (ts?: number | null, nowSec = Math.floor(Date.now() / 1000)): string => {
  if (ts == null || !Number.isFinite(Number(ts)) || Number(ts) <= 0) return '—';
  const expires = Number(ts);
  const days = Math.floor((expires - nowSec) / 86400);
  const date = new Date(expires * 1000);
  const dateStr = date.toLocaleDateString('ru-RU');
  if (days < 0) return `expired ${dateStr}`;
  if (days === 0) return `today (${dateStr})`;
  if (days === 1) return `1d (${dateStr})`;
  return `${days}d (${dateStr})`;
};

export const parseCatalogPayload = (data: unknown): SsCatalogConfig[] => {
  if (Array.isArray(data)) return data.filter((c): c is SsCatalogConfig => !!c && typeof c === 'object');
  if (data && typeof data === 'object' && Array.isArray((data as { data?: unknown }).data)) {
    return ((data as { data: unknown[] }).data).filter((c): c is SsCatalogConfig => !!c && typeof c === 'object');
  }
  return [];
};

export const catalogById = (catalog: SsCatalogConfig[], id?: string | number): SsCatalogConfig | undefined => {
  if (id == null || id === '') return undefined;
  const key = String(id);
  return catalog.find(
    (c) =>
      String(c.id) === key ||
      catalogTag(c) === key ||
      catalogTag(c) === `ss-${key}` ||
      c._ss_catalog_key === key
  );
};

export const catalogByTag = (catalog: SsCatalogConfig[], tag?: string): SsCatalogConfig | undefined => {
  if (!tag) return undefined;
  return catalog.find((c) => catalogTag(c) === tag);
};

export const outboundSsId = (proxy: { tag?: string; _ss_id?: string | number }): string | undefined => {
  if (proxy._ss_id != null && proxy._ss_id !== '') return String(proxy._ss_id);
  return ssIdFromTag(proxy.tag);
};

export type OutboundTitleSource = {
  tag?: string;
  _ss_title?: string;
  _ss_id?: string | number;
  _ss_source?: string;
  _ss_parent_id?: string | number | null;
};

export const outboundDisplayTitle = (proxy: OutboundTitleSource, catalog: SsCatalogConfig[] = []): string => {
  const byTag = catalogByTag(catalog, proxy.tag);
  if (byTag) return catalogTitle(byTag);
  const hit = catalogById(catalog, outboundSsId(proxy));
  if (hit) return catalogTitle(hit);
  if (proxy._ss_title) return proxy._ss_title;
  return proxy.tag && proxy.tag !== '' ? proxy.tag : 'no tag';
};

/** Resolve a routing/balancer tag to the human title shown in Outbounds. */
export const outboundTagDisplayTitle = (
  tag: string | undefined,
  outbounds: OutboundTitleSource[] = [],
  catalog: SsCatalogConfig[] = []
): string => {
  if (!tag) return 'no tag';
  const proxy = outbounds.find((o) => o.tag === tag);
  return proxy ? outboundDisplayTitle(proxy, catalog) : tag;
};

export const outboundApiOnline = (
  proxy: { tag?: string; _ss_id?: string | number; _ss_online?: boolean },
  catalog: SsCatalogConfig[] = []
): boolean | undefined => {
  const byTag = catalogByTag(catalog, proxy.tag);
  if (byTag && typeof byTag.is_online === 'boolean') return byTag.is_online;
  const hit = catalogById(catalog, outboundSsId(proxy));
  if (hit && typeof hit.is_online === 'boolean') return hit.is_online;
  if (typeof proxy._ss_online === 'boolean') return proxy._ss_online;
  return undefined;
};
