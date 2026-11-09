/** Classify Xray Observatory probe failures for the Outbounds UI. */

export type ProbeKind = 'alive' | 'pending' | 'timeout' | 'refused' | 'dns' | 'tls' | 'reality' | 'udp' | 'auth' | 'unreachable' | 'unknown';

export interface ProbeStatusInput {
  alive?: boolean;
  delay?: number;
  reason?: string;
}

export interface ProbeDiagnosis {
  kind: ProbeKind;
  /** i18n key under com.Outbounds.* */
  hintKey: string;
  rawReason?: string;
  delay?: number;
  /** Provider catalog says the config is online, but the router probe failed. */
  apiMismatch: boolean;
  /** StealthSurf ss-* outbound can be rebuilt from the API catalog. */
  canRefreshFromApi: boolean;
}

const has = (reason: string, ...needles: string[]) => needles.some((n) => reason.includes(n));

export const classifyProbeReason = (reason?: string): ProbeKind => {
  if (!reason) return 'unreachable';
  const r = reason.toLowerCase();

  if (has(r, 'reality', 'xtls-rprx')) return 'reality';
  if (has(r, 'tls handshake', 'certificate', 'x509', 'ssl', 'handshake failure', 'remote error: tls')) return 'tls';
  if (has(r, 'no such host', 'name resolution', 'dns', 'lookup ', 'temporary failure in name resolution')) return 'dns';
  // Prefer UDP/QUIC before generic timeout so Hysteria failures stay identifiable.
  if (has(r, 'dial udp', 'udp:', 'quic', 'hysteria')) return 'udp';
  if (has(r, 'context deadline', 'i/o timeout', 'timed out', 'timeout', 'deadline exceeded')) return 'timeout';
  if (has(r, 'connection refused', 'refused')) return 'refused';
  if (has(r, 'network is unreachable', 'no route to host', 'host unreachable', 'network unreachable')) return 'unreachable';
  if (has(r, 'authentication', 'auth failed', 'invalid user', 'rejected by server', 'unauthorized', '401', '403')) return 'auth';
  return 'unknown';
};

export const diagnoseOutboundProbe = (opts: {
  status?: ProbeStatusInput;
  apiOnline?: boolean;
  ssId?: string;
}): ProbeDiagnosis | undefined => {
  const { status, apiOnline, ssId } = opts;
  if (!status || status.alive === undefined) {
    return {
      kind: 'pending',
      hintKey: 'probe_hint_pending',
      apiMismatch: false,
      canRefreshFromApi: !!ssId
    };
  }
  if (status.alive) {
    return {
      kind: 'alive',
      hintKey: 'probe_hint_alive',
      delay: status.delay,
      apiMismatch: apiOnline === false,
      canRefreshFromApi: !!ssId
    };
  }

  const kind = classifyProbeReason(status.reason);
  return {
    kind,
    hintKey: `probe_hint_${kind}`,
    rawReason: status.reason,
    apiMismatch: apiOnline === true,
    canRefreshFromApi: !!ssId
  };
};

export const formatProbeStatusTitle = (
  diagnosis: ProbeDiagnosis | undefined,
  t: (key: string, args?: unknown[]) => string,
  ageSec?: number
): string => {
  if (!diagnosis) return '';
  const lines: string[] = [];

  if (diagnosis.kind === 'alive') {
    lines.push(diagnosis.delay !== undefined ? `${diagnosis.delay} ms` : t('com.Outbounds.probe_hint_alive'));
  } else if (diagnosis.kind === 'pending') {
    lines.push(t('com.Outbounds.probe_hint_pending'));
  } else {
    lines.push(t(`com.Outbounds.${diagnosis.hintKey}`));
    if (diagnosis.rawReason) lines.push(diagnosis.rawReason);
    else lines.push(t('com.Outbounds.status_unreachable'));
  }

  if (diagnosis.apiMismatch && diagnosis.kind !== 'alive') {
    lines.push(t('com.Outbounds.probe_api_mismatch'));
  } else if (diagnosis.apiMismatch && diagnosis.kind === 'alive') {
    lines.push(t('com.Outbounds.probe_api_offline_but_alive'));
  }

  if (diagnosis.canRefreshFromApi && diagnosis.kind !== 'alive' && diagnosis.kind !== 'pending') {
    lines.push(t('com.Outbounds.probe_refresh_hint'));
  }

  if (ageSec !== undefined) lines.push(t('com.Outbounds.balancer_checked', [ageSec]));
  return lines.join('\n');
};
