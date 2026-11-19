/** Persist standalone panel navigation across reloads (Save / Install / Apply). */

export type PanelView = 'home' | 'settings';

export type PanelSectionId =
  | 'account'
  | 'connection'
  | 'routing'
  | 'network'
  | 'outbounds'
  | 'engine'
  | 'logs'
  | 'clients'
  | 'updates'
  | 'help';

export interface PanelNavState {
  view: PanelView;
  section?: PanelSectionId;
}

const NAV_KEY = 'ss_panel_nav';
const SECTIONS: PanelSectionId[] = [
  'account',
  'connection',
  'routing',
  'network',
  'outbounds',
  'engine',
  'logs',
  'clients',
  'updates',
  'help'
];

function isPanel(): boolean {
  return !!(typeof window !== 'undefined' && (window as Window & { __SS_PANEL__?: boolean }).__SS_PANEL__);
}

export function loadPanelNav(): PanelNavState {
  if (!isPanel()) return { view: 'home' };
  try {
    const raw = sessionStorage.getItem(NAV_KEY);
    if (!raw) return { view: 'home' };
    const parsed = JSON.parse(raw) as PanelNavState;
    const view: PanelView = parsed?.view === 'settings' ? 'settings' : 'home';
    const section =
      parsed?.section && SECTIONS.includes(parsed.section) ? parsed.section : ('connection' as PanelSectionId);
    return { view, section };
  } catch {
    return { view: 'home' };
  }
}

export function savePanelNav(state: PanelNavState): void {
  if (!isPanel()) return;
  try {
    sessionStorage.setItem(
      NAV_KEY,
      JSON.stringify({
        view: state.view === 'settings' ? 'settings' : 'home',
        section: state.section && SECTIONS.includes(state.section) ? state.section : 'connection'
      } satisfies PanelNavState)
    );
  } catch {
    /* ignore quota / private mode */
  }
}
