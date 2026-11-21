import { XrayUiGlobal } from '@/global';
import { compareVersions, installedVersion, syncDisplayedVersion } from '@/modules/SurfGateUpdate';

describe('SurfGateUpdate version helpers', () => {
  beforeEach(() => {
    window.xray = { router: {}, server: {}, custom_settings: {} } as unknown as XrayUiGlobal;
  });

  it('compareVersions orders dotted releases', () => {
    expect(compareVersions('1.4.44', '1.4.43')).toBe(1);
    expect(compareVersions('1.4.43', '1.4.44')).toBe(-1);
    expect(compareVersions('1.4.44', '1.4.44')).toBe(0);
  });

  it('installedVersion prefers live ui_version over a stale custom_settings cache', () => {
    window.xray.custom_settings.stealthsurf_version = '1.4.43';
    expect(installedVersion('1.4.45')).toBe('1.4.45');
  });

  it('installedVersion keeps a newer custom_settings when ui_version lags', () => {
    window.xray.custom_settings.stealthsurf_version = '1.4.45';
    expect(installedVersion('1.4.43')).toBe('1.4.45');
  });

  it('installedVersion falls back to custom_settings when ui_version is missing', () => {
    window.xray.custom_settings.stealthsurf_version = '1.4.43';
    expect(installedVersion()).toBe('1.4.43');
  });

  it('syncDisplayedVersion heals a stale custom_settings cache', () => {
    window.xray.custom_settings.stealthsurf_version = '1.4.43';
    expect(syncDisplayedVersion('1.4.45')).toBe('1.4.45');
    expect(window.xray.custom_settings.stealthsurf_version).toBe('1.4.45');
  });
});
