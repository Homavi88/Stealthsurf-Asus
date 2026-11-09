import { classifyProbeReason, diagnoseOutboundProbe, formatProbeStatusTitle } from './OutboundProbeHint';

describe('classifyProbeReason', () => {
  it('maps common Xray Observatory errors', () => {
    expect(classifyProbeReason('context deadline exceeded')).toBe('timeout');
    expect(classifyProbeReason('dial tcp 1.2.3.4:443: i/o timeout')).toBe('timeout');
    expect(classifyProbeReason('dial tcp 1.2.3.4:443: connection refused')).toBe('refused');
    expect(classifyProbeReason('lookup example.com: no such host')).toBe('dns');
    expect(classifyProbeReason('TLS handshake timeout')).toBe('tls');
    expect(classifyProbeReason('REALITY: processed invalid connection')).toBe('reality');
    expect(classifyProbeReason('dial udp 1.2.3.4:443: i/o timeout')).toBe('udp');
    expect(classifyProbeReason('authentication failed')).toBe('auth');
    expect(classifyProbeReason('network is unreachable')).toBe('unreachable');
    expect(classifyProbeReason('something weird')).toBe('unknown');
    expect(classifyProbeReason(undefined)).toBe('unreachable');
  });
});

describe('diagnoseOutboundProbe', () => {
  it('marks pending when Observatory has no result yet', () => {
    expect(diagnoseOutboundProbe({ status: { alive: undefined }, ssId: '1' })).toMatchObject({
      kind: 'pending',
      canRefreshFromApi: true,
      apiMismatch: false
    });
  });

  it('flags API online + dead probe as a mismatch that can be refreshed', () => {
    const d = diagnoseOutboundProbe({
      status: { alive: false, reason: 'context deadline exceeded' },
      apiOnline: true,
      ssId: '69191'
    });
    expect(d).toMatchObject({
      kind: 'timeout',
      hintKey: 'probe_hint_timeout',
      apiMismatch: true,
      canRefreshFromApi: true,
      rawReason: 'context deadline exceeded'
    });
  });

  it('does not treat non-StealthSurf outbounds as refreshable', () => {
    const d = diagnoseOutboundProbe({
      status: { alive: false, reason: 'connection refused' },
      apiOnline: undefined
    });
    expect(d?.canRefreshFromApi).toBe(false);
    expect(d?.apiMismatch).toBe(false);
  });

  it('formats a multi-line status title for tooltips', () => {
    const d = diagnoseOutboundProbe({
      status: { alive: false, reason: 'REALITY rejected' },
      apiOnline: true,
      ssId: '9'
    });
    const title = formatProbeStatusTitle(d, (k) => k, 12);
    expect(title).toContain('com.Outbounds.probe_hint_reality');
    expect(title).toContain('REALITY rejected');
    expect(title).toContain('com.Outbounds.probe_api_mismatch');
    expect(title).toContain('com.Outbounds.probe_refresh_hint');
    expect(title).toContain('com.Outbounds.balancer_checked');
  });
});
