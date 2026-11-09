import {
  catalogSourceLabel,
  catalogTag,
  catalogTitle,
  formatExpiresAt,
  outboundApiOnline,
  outboundDisplayTitle,
  outboundSsId,
  outboundTagDisplayTitle,
  parseCatalogPayload,
  ssIdFromTag
} from './StealthSurfCatalog';

const catalog = [
  { id: 69191, title: 'Нидерланды VLESS XHTTP', protocol: 'vless', is_online: true, expires_at: 2000000000, _ss_location_title: 'NL' },
  { id: 228111, name: 'Hysteria NL', protocol: 'hysteria', is_online: false },
  {
    id: 55,
    title: 'Paid DE',
    protocol: 'vless',
    is_online: true,
    _ss_source: 'paid_option',
    _ss_tag: 'ss-po-55',
    _ss_parent_id: 4
  }
];

const outbounds = [
  { tag: 'ss-69191', _ss_title: 'Saved title' },
  { tag: 'ss-228111' },
  { tag: 'ss-po-55', _ss_id: 55, _ss_source: 'paid_option' },
  { tag: 'direct' }
];

describe('StealthSurfCatalog', () => {
  it('parses ss-<id> and paid/cloud tags', () => {
    expect(ssIdFromTag('ss-69191')).toBe('69191');
    expect(ssIdFromTag('ss-po-55')).toBe('55');
    expect(ssIdFromTag('ss-cs-9')).toBe('9');
    expect(ssIdFromTag('ss-po-wi-4-0')).toBe('0');
    expect(ssIdFromTag('direct')).toBeUndefined();
    expect(ssIdFromTag('ss-foo')).toBeUndefined();
  });

  it('prefers live catalog title (API keys), then stored snapshot, then tag', () => {
    expect(outboundDisplayTitle({ tag: 'ss-69191', _ss_title: 'Saved title' }, catalog)).toBe('Нидерланды VLESS XHTTP');
    expect(outboundDisplayTitle({ tag: 'ss-69191', _ss_title: 'Saved title' }, [])).toBe('Saved title');
    expect(outboundDisplayTitle({ tag: 'ss-69191' }, catalog)).toBe('Нидерланды VLESS XHTTP');
    expect(outboundDisplayTitle({ tag: 'ss-228111' }, catalog)).toBe('Hysteria NL');
    expect(outboundDisplayTitle({ tag: 'ss-po-55' }, catalog)).toBe('Paid DE');
    expect(outboundDisplayTitle({ tag: 'ss-1' }, catalog)).toBe('ss-1');
    expect(outboundDisplayTitle({ tag: '' }, [])).toBe('no tag');
  });

  it('labels rule/balancer dropdown tags via outbound title lookup', () => {
    expect(outboundTagDisplayTitle('ss-69191', outbounds, catalog)).toBe('Нидерланды VLESS XHTTP');
    expect(outboundTagDisplayTitle('ss-69191', outbounds, [])).toBe('Saved title');
    expect(outboundTagDisplayTitle('ss-228111', outbounds, catalog)).toBe('Hysteria NL');
    expect(outboundTagDisplayTitle('ss-po-55', outbounds, catalog)).toBe('Paid DE');
    expect(outboundTagDisplayTitle('direct', outbounds, [])).toBe('direct');
    expect(outboundTagDisplayTitle('ss-missing', outbounds, [])).toBe('ss-missing');
    expect(outboundTagDisplayTitle(undefined, outbounds, [])).toBe('no tag');
  });

  it('parses catalog payloads as a bare array or {data:[...]}', () => {
    expect(parseCatalogPayload(catalog)).toEqual(catalog);
    expect(parseCatalogPayload({ data: catalog })).toEqual(catalog);
    expect(parseCatalogPayload(null)).toEqual([]);
  });

  it('reads API online from catalog, then the snapshot on the outbound', () => {
    expect(outboundApiOnline({ tag: 'ss-69191' }, catalog)).toBe(true);
    expect(outboundApiOnline({ tag: 'ss-228111' }, catalog)).toBe(false);
    expect(outboundApiOnline({ tag: 'ss-1', _ss_online: true }, catalog)).toBe(true);
    expect(outboundApiOnline({ tag: 'direct' }, catalog)).toBeUndefined();
  });

  it('resolves id from _ss_id when the tag was renamed', () => {
    expect(outboundSsId({ tag: 'nl-vless', _ss_id: 69191 })).toBe('69191');
    expect(catalogTitle(catalog[0])).toBe('Нидерланды VLESS XHTTP');
    expect(catalogTag(catalog[2])).toBe('ss-po-55');
    expect(catalogSourceLabel(catalog[2])).toBe('paid');
    expect(catalogSourceLabel(catalog[0])).toBe('vpn');
  });

  it('formats expires_at relative to now', () => {
    const now = 1_700_000_000;
    expect(formatExpiresAt(now + 86400 * 3, now)).toContain('3d');
    expect(formatExpiresAt(now - 10, now)).toContain('expired');
    expect(formatExpiresAt(undefined)).toBe('—');
  });
});
