import { shallowMount } from '@vue/test-utils';
import { defineComponent, h, nextTick } from 'vue';
import RulesModal from '@modal/RulesModal.vue';
import { XrayRoutingRuleObject } from '@/modules/CommonObjects';
import xrayConfig from '@/modules/XrayConfig';
import { XrayOutboundObject } from '@/modules/OutboundObjects';

jest.mock('vue-i18n', () => ({
  useI18n: () => ({ t: (k: string) => k })
}));

const ModalStub = defineComponent({
  name: 'ModalStub',
  setup(_, { slots, expose }) {
    expose({ show: () => undefined, close: () => undefined });
    return () => h('div', slots.default?.());
  }
});

interface RulesModalVm {
  rules: { ip?: string[]; source?: string[]; domain?: string[] }[];
  ips: string;
  source: string;
  domains: string;
  addRule: () => void;
  saveRule: () => void;
}

describe('RulesModal custom geodata lists', () => {
  let alertSpy: jest.SpyInstance;

  beforeEach(() => {
    alertSpy = jest.spyOn(window, 'alert').mockImplementation(() => undefined);
  });

  afterEach(() => alertSpy.mockRestore());

  const mountModal = () => {
    const wrapper = shallowMount(RulesModal, {
      props: { rules: [], disabled_rules: [] },
      global: { stubs: { modal: ModalStub, hint: true, draggable: true, teleport: true }, mocks: { $t: (k: string) => k } }
    });
    const vm = wrapper.vm as unknown as RulesModalVm;
    vm.addRule();
    return vm;
  };

  it('refuses ext:stealthsurf: lists in the target IP list', () => {
    const vm = mountModal();
    vm.ips = '1.1.1.1/32\next:stealthsurf:viber-geoip';
    vm.saveRule();
    expect(alertSpy).toHaveBeenCalledWith('com.RulesModal.alert_ext_xrayui_in_ips');
    expect(vm.rules).toHaveLength(0);
  });

  it('refuses ext:stealthsurf: lists in the source IP list', () => {
    const vm = mountModal();
    vm.source = 'EXT:STEALTHSURF:viber-geoip';
    vm.saveRule();
    expect(alertSpy).toHaveBeenCalled();
    expect(vm.rules).toHaveLength(0);
  });

  it('keeps ext:stealthsurf: lists in the domain list and other ext: files in IP lists', () => {
    const vm = mountModal();
    vm.domains = 'ext:stealthsurf:viber';
    vm.ips = 'ext:geoip_custom.dat:viber\ngeoip:cloudflare';
    vm.saveRule();
    expect(alertSpy).not.toHaveBeenCalled();
    expect(vm.rules).toHaveLength(1);
    expect(vm.rules[0].domain).toEqual(['ext:stealthsurf:viber']);
    expect(vm.rules[0].ip).toEqual(['ext:geoip_custom.dat:viber', 'geoip:cloudflare']);
  });
});

describe('RulesModal popular services', () => {
  interface PopularVm {
    show: (onClose: () => void) => void;
    createPopularRules: () => void;
    rules: XrayRoutingRuleObject[];
  }

  let alertSpy: jest.SpyInstance;
  let confirmSpy: jest.SpyInstance;

  beforeEach(() => {
    alertSpy = jest.spyOn(window, 'alert').mockImplementation(() => undefined);
    confirmSpy = jest.spyOn(window, 'confirm').mockReturnValue(true);
  });

  afterEach(() => {
    alertSpy.mockRestore();
    confirmSpy.mockRestore();
    xrayConfig.outbounds = [];
    xrayConfig.inbounds = [];
  });

  it('alerts when there is no proxy outbound', async () => {
    xrayConfig.outbounds = [Object.assign(new XrayOutboundObject(), { tag: 'direct', protocol: 'freedom' })];
    const wrapper = shallowMount(RulesModal, {
      props: { rules: [], disabled_rules: [] },
      global: { stubs: { modal: ModalStub, hint: true, draggable: true, teleport: true }, mocks: { $t: (k: string) => k } }
    });
    const vm = wrapper.vm as unknown as PopularVm;
    vm.show(() => undefined);
    await nextTick();
    vm.createPopularRules();
    expect(alertSpy).toHaveBeenCalledWith('com.RulesModal.alert_popular_no_proxy');
    expect(vm.rules).toHaveLength(0);
  });

  it('adds domain + IP + Discord popular rules to the first proxy outbound', async () => {
    xrayConfig.outbounds = [
      Object.assign(new XrayOutboundObject(), { tag: 'direct', protocol: 'freedom' }),
      Object.assign(new XrayOutboundObject(), { tag: 'ss-1', protocol: 'vless', _ss_title: 'NL' }),
      Object.assign(new XrayOutboundObject(), { tag: 'block', protocol: 'blackhole' })
    ];
    const wrapper = shallowMount(RulesModal, {
      props: { rules: [], disabled_rules: [] },
      global: { stubs: { modal: ModalStub, hint: true, draggable: true, teleport: true }, mocks: { $t: (k: string) => k } }
    });
    const vm = wrapper.vm as unknown as PopularVm;
    vm.show(() => undefined);
    await nextTick();
    vm.createPopularRules();

    expect(confirmSpy).toHaveBeenCalled();
    expect(vm.rules).toHaveLength(3);
    expect(vm.rules.map((r) => r.name)).toEqual(['Common services (domains)', 'Common services (IPs)', 'Discord voice/video']);
    expect(vm.rules.every((r) => r.outboundTag === 'ss-1')).toBe(true);
    expect(vm.rules[0].domain).toEqual(expect.arrayContaining(['geosite:youtube', 'geosite:telegram']));
    expect(vm.rules[1].ip).toEqual(expect.arrayContaining(['geoip:telegram']));
  });
});

describe('RulesModal outbound titles', () => {
  interface TitlesVm {
    show: (onClose: () => void) => void;
    targetOptions: { key: string; label: string }[];
    usedTargets: { key: string; label: string; count: number }[];
    reassignField: 'outbound' | 'inbound';
    reassignFromOptions: { key: string; label: string; count: number }[];
    labelOutbound: (tag: string | undefined) => string;
    getRuleName: (rule: XrayRoutingRuleObject) => string;
  }

  afterEach(() => {
    xrayConfig.outbounds = [];
    xrayConfig.inbounds = [];
    if (xrayConfig.routing) xrayConfig.routing.balancers = [];
  });

  it('shows API titles instead of ss-<id> in rule target dropdowns', async () => {
    const titled = Object.assign(new XrayOutboundObject(), { tag: 'ss-69191', _ss_title: 'Нидерланды VLESS XHTTP' });
    xrayConfig.outbounds = [
      Object.assign(new XrayOutboundObject(), { tag: 'direct' }),
      titled,
      Object.assign(new XrayOutboundObject(), { tag: 'block' })
    ];
    xrayConfig.inbounds = [];
    if (xrayConfig.routing) xrayConfig.routing.balancers = [];

    const proxyRule = Object.assign(new XrayRoutingRuleObject(), {
      idx: 0,
      name: '',
      outboundTag: 'ss-69191',
      inboundTag: [],
      domain: ['geosite:cn'],
      enabled: true
    });
    const wrapper = shallowMount(RulesModal, {
      props: { rules: [proxyRule], disabled_rules: [] },
      global: { stubs: { modal: ModalStub, hint: true, draggable: true, teleport: true }, mocks: { $t: (k: string) => k } }
    });
    const vm = wrapper.vm as unknown as TitlesVm;
    vm.show(() => undefined);
    await nextTick();

    expect(vm.labelOutbound('ss-69191')).toBe('Нидерланды VLESS XHTTP');
    expect(vm.targetOptions.find((o) => o.key === 'o:ss-69191')?.label).toBe('Нидерланды VLESS XHTTP');
    expect(vm.usedTargets.find((o) => o.key === 'o:ss-69191')?.label).toBe('Нидерланды VLESS XHTTP');
    expect(vm.reassignFromOptions.find((o) => o.key === 'o:ss-69191')?.label).toBe('Нидерланды VLESS XHTTP');
    expect(vm.getRuleName(proxyRule)).toContain('Нидерланды VLESS XHTTP');
    expect(vm.getRuleName(proxyRule)).not.toContain('ss-69191');
  });
});

describe('RulesModal reassigning an inbound', () => {
  interface ReassignVm {
    show: (onClose: () => void) => void;
    reassignField: 'outbound' | 'inbound';
    reassignFrom: string;
    reassignTo: string;
    reassignPlan: { change: XrayRoutingRuleObject[]; skip: XrayRoutingRuleObject[] };
    reassign: () => void;
  }

  const rule = (idx: number, name: string, inboundTag: string[], enabled = true) =>
    Object.assign(new XrayRoutingRuleObject(), { idx, name, outboundTag: 'proxy', inboundTag, enabled });

  const setup = async () => {
    const only = rule(0, 'only socks-in', ['socks-in']);
    const duplicate = rule(1, 'socks-in twice', ['socks-in', 'socks-in']);
    const multi = rule(2, 'socks-in and tproxy-in', ['socks-in', 'tproxy-in']);
    const system = rule(3, 'sys:metrics', ['socks-in', 'tproxy-in']);
    const disabled = rule(4, 'disabled socks-in and new-in', ['socks-in', 'new-in'], false);
    const wrapper = shallowMount(RulesModal, {
      props: { rules: [only, duplicate, multi, system], disabled_rules: [disabled] },
      global: { stubs: { modal: ModalStub, hint: true, draggable: true, teleport: true }, mocks: { $t: (k: string) => k } }
    });
    const vm = wrapper.vm as unknown as ReassignVm;
    vm.show(() => undefined);
    vm.reassignField = 'inbound';
    await nextTick(); // switching the field resets From and To
    vm.reassignFrom = 'i:socks-in';
    return { vm, only, duplicate, multi, system, disabled };
  };

  it("never removes a rule's last inbound, which would make the rule match every inbound", async () => {
    const { vm, only, duplicate, multi, system, disabled } = await setup();
    vm.reassignTo = 'remove';

    expect(vm.reassignPlan.skip).toHaveLength(2);
    vm.reassign();

    expect(only.inboundTag).toEqual(['socks-in']);
    expect(duplicate.inboundTag).toEqual(['socks-in', 'socks-in']);
    expect(multi.inboundTag).toEqual(['tproxy-in']);
    expect(disabled.inboundTag).toEqual(['new-in']);
    expect(disabled.enabled).toBe(false);
    expect(system.inboundTag).toEqual(['socks-in', 'tproxy-in']);
  });

  it('replaces an inbound without listing the new one twice', async () => {
    const { vm, only, multi, system, disabled } = await setup();
    vm.reassignTo = 'i:new-in';
    vm.reassign();

    expect(only.inboundTag).toEqual(['new-in']);
    expect(multi.inboundTag).toEqual(['new-in', 'tproxy-in']);
    expect(disabled.inboundTag).toEqual(['new-in']);
    expect(system.inboundTag).toEqual(['socks-in', 'tproxy-in']);
  });
});
