/**
 * @jest-environment jsdom
 */
jest.mock('axios', () => ({ get: jest.fn(), post: jest.fn() }));

import axios from 'axios';
import engine, { SubmitActions } from '@modules/Engine';

const post = axios.post as jest.Mock;

function enablePanel(): void {
  (window as Window & { __SS_PANEL__?: boolean }).__SS_PANEL__ = true;
  window.xray = {
    router: {},
    server: {},
    commands: {},
    geotags: {},
    custom_settings: { stealthsurf_version: '1.2.0', other_addon: 'nope' }
  } as unknown as typeof window.xray;
}

describe('Engine standalone panel submit', () => {
  beforeEach(() => {
    post.mockReset();
    post.mockResolvedValue({ data: { ok: true } });
    enablePanel();
  });

  afterEach(() => {
    delete (window as Window & { __SS_PANEL__?: boolean }).__SS_PANEL__;
  });

  it('posts action + stealthsurf_ settings to /cgi-bin/api', async () => {
    await engine.submit(SubmitActions.initResponse, null, 0);

    expect(post).toHaveBeenCalledTimes(1);
    expect(post.mock.calls[0][0]).toBe('/cgi-bin/api');
    expect(post.mock.calls[0][1]).toEqual({
      action: SubmitActions.initResponse,
      settings: { stealthsurf_version: '1.2.0' }
    });
  });

  it('chunks payload into stealthsurf_payload* settings', async () => {
    await engine.submit(SubmitActions.configurationApply, { hello: 'world' }, 0);

    const body = post.mock.calls[0][1] as { action: string; settings: Record<string, string> };
    expect(body.action).toBe(SubmitActions.configurationApply);
    expect(body.settings.stealthsurf_payload0).toContain('hello');
    expect(body.settings.stealthsurf_version).toBe('1.2.0');
    expect(body.settings.other_addon).toBeUndefined();
  });

  it('posts absolute setstartup with current stealthsurf_startup setting', async () => {
    window.xray.custom_settings.stealthsurf_startup = 'y';
    await engine.submit(SubmitActions.setStartupOption, null, 0);

    expect(post.mock.calls[0][1]).toEqual({
      action: SubmitActions.setStartupOption,
      settings: { stealthsurf_version: '1.2.0', stealthsurf_startup: 'y' }
    });
  });
});
