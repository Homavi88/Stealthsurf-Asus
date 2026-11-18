import { SubmitActions } from '@/modules/Engine';

describe('VPN hardening wiring', () => {
  it('exposes preflight submit action', () => {
    expect(SubmitActions.preflight).toBe('stealthsurf_preflight');
  });

  it('keeps addon update check action for GitHub auto-update (#9)', () => {
    expect(SubmitActions.addonUpdateCheck).toBe('stealthsurf_addonupdatecheck');
  });
});
