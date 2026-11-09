export interface SsCatalogConfig {
  id: number | string;
  title?: string;
  name?: string;
  protocol?: string;
  is_online?: boolean;
  connection_url?: string;
}

export const SS_DEFAULT_RULE = 'stealthsurf-default';

export const ssIdFromTag = (tag?: string): string | undefined => {
  const m = tag?.match(/^ss-(\d+)$/);
  return m?.[1];
};

export const catalogTitle = (c: SsCatalogConfig): string => c.title || c.name || `ss-${c.id}`;

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
  return catalog.find((c) => String(c.id) === key);
};

export const outboundSsId = (proxy: { tag?: string; _ss_id?: string | number }): string | undefined => {
  if (proxy._ss_id != null && proxy._ss_id !== '') return String(proxy._ss_id);
  return ssIdFromTag(proxy.tag);
};

export type OutboundTitleSource = { tag?: string; _ss_title?: string; _ss_id?: string | number };

export const outboundDisplayTitle = (proxy: OutboundTitleSource, catalog: SsCatalogConfig[] = []): string => {
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
  const hit = catalogById(catalog, outboundSsId(proxy));
  if (hit && typeof hit.is_online === 'boolean') return hit.is_online;
  if (typeof proxy._ss_online === 'boolean') return proxy._ss_online;
  return undefined;
};
