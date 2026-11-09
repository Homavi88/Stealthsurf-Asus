import {
  formatBytes,
  statsPathForConfig,
  trafficQueryPath,
  trafficScopeForConfig
} from './StealthSurfApiClient';

describe('StealthSurfApiClient helpers', () => {
  it('builds stats paths by source', () => {
    expect(statsPathForConfig({ id: 10 })).toBe('/configs/10/serverStats');
    expect(statsPathForConfig({ id: 55, _ss_source: 'paid_option', _ss_parent_id: 4 })).toBe(
      '/paid-options/4/configs/55/stats'
    );
    expect(statsPathForConfig({ id: 9, _ss_source: 'cloud', _ss_parent_id: 3 })).toBe('/cloud-servers/3/serverStats');
  });

  it('picks traffic scope for catalog rows', () => {
    expect(trafficScopeForConfig({ id: 10 })).toEqual({ scope_type: 'user_config', scope_id: 10 });
    expect(trafficScopeForConfig({ id: 55, _ss_source: 'paid_option' })).toEqual({
      scope_type: 'paid_option_config',
      scope_id: 55
    });
  });

  it('builds traffic query with from/to/group_by', () => {
    const path = trafficQueryPath('user_config', 101, 'day', 30);
    expect(path.startsWith('/traffic?')).toBe(true);
    expect(path).toContain('group_by=day');
    expect(path).toContain('scope_type=user_config');
    expect(path).toContain('scope_id=101');
    expect(path).toContain('from=');
    expect(path).toContain('to=');
  });

  it('formats byte totals', () => {
    expect(formatBytes(512)).toBe('512 B');
    expect(formatBytes('1048576')).toContain('MB');
    expect(formatBytes(undefined)).toBe('—');
  });
});
