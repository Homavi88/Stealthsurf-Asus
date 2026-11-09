import axios, { AxiosRequestConfig } from 'axios';
import engine from '@/modules/Engine';
import type { SsCatalogConfig } from '@/modules/StealthSurfCatalog';

export const SS_API_BASE = 'https://api.stealthsurf.net';

export type SsApiEnvelope<T> = {
  status?: boolean;
  statusCode?: number;
  data?: T;
  message?: string;
  errorCode?: number;
};

/** First saved API key from router cache (full key stays on router/WebUI share). */
export const getPrimaryApiKey = async (): Promise<string | null> => {
  try {
    const keysResp = await engine.getWebData<{ key?: string }[]>('api_keys');
    const keys = Array.isArray(keysResp?.data) ? keysResp.data : [];
    const hit = keys.find((k) => typeof k?.key === 'string' && k.key.startsWith('stlth_'));
    return hit?.key || null;
  } catch {
    return null;
  }
};

export const ssApiGet = async <T>(path: string, config: AxiosRequestConfig = {}): Promise<T> => {
  const key = await getPrimaryApiKey();
  if (!key) throw new Error('No API key saved — add a key first');
  const { data } = await axios.get<SsApiEnvelope<T>>(`${SS_API_BASE}${path}`, {
    ...config,
    headers: {
      Authorization: `Bearer ${key}`,
      Accept: 'application/json',
      ...(config.headers || {})
    },
    timeout: config.timeout ?? 15000
  });
  if (data && typeof data === 'object' && data.status === false) {
    throw new Error(data.message || `API error ${data.errorCode ?? ''}`.trim());
  }
  return (data?.data ?? data) as T;
};

export const statsPathForConfig = (c: SsCatalogConfig): string => {
  const source = c._ss_source || 'config';
  const id = c.id;
  const parent = c._ss_parent_id;
  if (source === 'paid_option' && parent != null && parent !== '') {
    return `/paid-options/${parent}/configs/${id}/stats`;
  }
  if (source === 'cloud' && parent != null && parent !== '') {
    return `/cloud-servers/${parent}/serverStats`;
  }
  return `/configs/${id}/serverStats`;
};

export const trafficScopeForConfig = (c: SsCatalogConfig): { scope_type: string; scope_id?: number | string } => {
  const source = c._ss_source || 'config';
  if (source === 'paid_option') return { scope_type: 'paid_option_config', scope_id: c.id };
  if (source === 'cloud') return { scope_type: 'cloud_config', scope_id: c.id };
  return { scope_type: 'user_config', scope_id: c.id };
};

export const trafficQueryPath = (
  scope_type: string,
  scope_id: number | string | undefined,
  group_by: 'hour' | 'day' | 'week' | 'month' = 'day',
  days = 30
): string => {
  const now = Math.floor(Date.now() / 1000);
  const from = Math.max(0, now - days * 86400);
  const params = new URLSearchParams({
    from: String(from),
    to: String(now),
    group_by
  });
  if (scope_type && scope_type !== 'account') {
    params.set('scope_type', scope_type);
    if (scope_id != null && scope_id !== '') params.set('scope_id', String(scope_id));
  } else {
    params.set('scope_type', 'account');
  }
  return `/traffic?${params.toString()}`;
};

export const formatBytes = (raw: string | number | null | undefined): string => {
  if (raw == null || raw === '') return '—';
  const n = typeof raw === 'string' ? Number(raw) : Number(raw);
  if (!Number.isFinite(n) || n < 0) return '—';
  if (n < 1024) return `${n} B`;
  const units = ['KB', 'MB', 'GB', 'TB'];
  let v = n;
  let i = -1;
  do {
    v /= 1024;
    i += 1;
  } while (v >= 1024 && i < units.length - 1);
  return `${v.toFixed(v >= 10 || i === 0 ? 1 : 2)} ${units[i]}`;
};

export type ServerStatsPayload = {
  host?: string;
  status?: string;
  uptime_days?: number;
  cpu_model?: string;
  stats?: { date?: string; cpu?: number; ram?: number; up?: number; down?: number }[];
} | null;

export type TrafficPayload = {
  total_bytes?: string;
  points?: { start?: number; total_bytes?: string }[];
  scope?: { type?: string; id?: number | null; title?: string | null; protocol?: string | null };
} | null;
