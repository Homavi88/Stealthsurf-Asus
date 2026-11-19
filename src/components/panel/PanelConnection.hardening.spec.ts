import { SubmitActions } from '@/modules/Engine';

describe('VPN hardening wiring', () => {
  it('exposes preflight submit action', () => {
    expect(SubmitActions.preflight).toBe('stealthsurf_preflight');
  });

  it('exposes speed test and DNS leak test actions', () => {
    expect(SubmitActions.speedTest).toBe('stealthsurf_speedtest');
    expect(SubmitActions.dnsTest).toBe('stealthsurf_dnstest');
  });

  it('keeps addon update check action for GitHub auto-update (#9)', () => {
    expect(SubmitActions.addonUpdateCheck).toBe('stealthsurf_addonupdatecheck');
  });

  it('keeps performUpdate for Settings → Updates install button', () => {
    expect(SubmitActions.performUpdate).toBe('stealthsurf_update');
  });
});
