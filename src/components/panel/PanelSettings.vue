<template>
  <div class="ss-settings-page">
    <header class="ss-settings-top">
      <button type="button" class="ss-back-link" @click="$emit('back')">← На главную</button>
      <h2 class="ss-settings-title">Настройки</h2>
    </header>

    <nav class="ss-mobile-nav" aria-label="Разделы настроек">
      <button
        v-for="item in allNav"
        :key="'m-' + item.id"
        type="button"
        class="ss-mobile-nav-item"
        :class="{ 'is-active': section === item.id }"
        @click="setSection(item.id)"
      >
        <span class="ss-nav-ico">{{ item.icon }}</span>
        {{ item.label }}
      </button>
    </nav>

    <div class="ss-settings-layout">
      <aside class="ss-settings-aside">
        <div class="ss-profile-card">
          <div class="ss-profile-card__email">{{ profile.email || 'Аккаунт SurfGate' }}</div>
          <div class="ss-profile-card__balance">{{ profile.balance || '— ₽' }}</div>
          <div class="ss-profile-card__sub">{{ profile.label || 'Основная подписка' }}</div>
        </div>

        <div class="ss-nav-search">
          <span aria-hidden="true">⌕</span>
          <input v-model="navQuery" type="search" placeholder="Поиск настроек" />
        </div>

        <div class="ss-nav-group" v-if="filteredPrimary.length">
          <button
            v-for="item in filteredPrimary"
            :key="item.id"
            type="button"
            class="ss-nav-item"
            :class="{ 'is-active': section === item.id }"
            @click="setSection(item.id)"
          >
            <span class="ss-nav-ico">{{ item.icon }}</span>
            {{ item.label }}
            <span class="ss-nav-chev">›</span>
          </button>
        </div>
        <div class="ss-nav-group" v-if="filteredEngine.length">
          <button
            v-for="item in filteredEngine"
            :key="item.id"
            type="button"
            class="ss-nav-item"
            :class="{ 'is-active': section === item.id }"
            @click="setSection(item.id)"
          >
            <span class="ss-nav-ico">{{ item.icon }}</span>
            {{ item.label }}
            <span class="ss-nav-chev">›</span>
          </button>
        </div>
        <div class="ss-nav-group" v-if="filteredMore.length">
          <button
            v-for="item in filteredMore"
            :key="item.id"
            type="button"
            class="ss-nav-item"
            :class="{ 'is-active': section === item.id }"
            @click="setSection(item.id)"
          >
            <span class="ss-nav-ico">{{ item.icon }}</span>
            {{ item.label }}
            <span class="ss-nav-chev">›</span>
          </button>
        </div>
      </aside>

      <section
        class="ss-settings-pane"
        :class="{
          'is-native': section === 'connection' || section === 'account' || section === 'help'
        }"
      >
        <h2 class="ss-pane-heading">{{ currentLabel }}</h2>

        <div v-if="section === 'account'">
          <panel-account @profile="onProfile" />
        </div>

        <div v-else-if="section === 'connection'">
          <panel-connection :config="config" />
        </div>

        <div v-else-if="section === 'routing'" class="ss-panel-light">
          <routing />
        </div>

        <div v-else-if="section === 'network'" class="ss-panel-light">
          <inbounds @show-transport="emitTransport" @show-sniffing="emitSniffing" />
          <dns />
          <reverse-proxy />
        </div>

        <div v-else-if="section === 'outbounds'" class="ss-panel-light">
          <outbounds @show-transport="emitTransport" />
        </div>

        <div v-else-if="section === 'engine'" class="ss-panel-light">
          <service-status :config="config" />
        </div>

        <div v-else-if="section === 'logs'" class="ss-panel-light">
          <logs-manager v-model:logs="config.log!" />
          <sni-logs />
        </div>

        <div v-else-if="section === 'clients'" class="ss-panel-light">
          <p v-if="!clientsCheckEnabled" class="ss-empty" style="padding: 12px">
            Включите «Клиенты онлайн» в Подключение / General Options — иначе опрос устройств не запускается (экономия RAM).
          </p>
          <clients-online v-else />
        </div>

        <div v-else-if="section === 'updates'" class="ss-panel-light">
          <panel-updates :config="config" />
        </div>

        <div v-else-if="section === 'help'" class="ss-panel-help">
          <panel-help />
        </div>

        <div class="ss-apply-wrap" v-if="needsApply">
          <button type="button" class="ss-primary-btn start" @click.prevent="$emit('apply')">Применить</button>
        </div>
      </section>
    </div>
  </div>
</template>

<script lang="ts">
  import { computed, defineComponent, inject, onMounted, PropType, ref, Ref } from 'vue';
  import { XrayObject } from '@/modules/XrayConfig';
  import engine, { EngineResponseConfig } from '@/modules/Engine';
  import ServiceStatus from '../ServiceStatus.vue';
  import Routing from '../Routing.vue';
  import Inbounds from '../Inbounds.vue';
  import Outbounds from '../Outbounds.vue';
  import Dns from '../Dns.vue';
  import ReverseProxy from '../ReverseProxy.vue';
  import ClientsOnline from '../ClientsOnline.vue';
  import LogsManager from '../Logs.vue';
  import SniLogs from '../SniLogs.vue';
  import PanelUpdates from './PanelUpdates.vue';
  import PanelConnection from './PanelConnection.vue';
  import PanelHelp from './PanelHelp.vue';
  import PanelAccount from './PanelAccount.vue';
  import { PanelSectionId } from './panelNav';

  type SectionId = PanelSectionId;

  type NavItem = { id: SectionId; label: string; icon: string };

  type ProfileInfo = { email?: string; balance?: string; label?: string };

  export default defineComponent({
    name: 'PanelSettings',
    components: {
      PanelAccount,
      ServiceStatus,
      Routing,
      Inbounds,
      Outbounds,
      Dns,
      ReverseProxy,
      ClientsOnline,
      LogsManager,
      SniLogs,
      PanelUpdates,
      PanelConnection,
      PanelHelp
    },
    props: {
      config: { type: Object as PropType<XrayObject>, required: true },
      initialSection: { type: String as PropType<SectionId>, default: 'connection' }
    },
    emits: ['back', 'apply', 'show-transport', 'show-sniffing', 'section-change'],
    setup(props, { emit }) {
      const uiResponse = inject<Ref<EngineResponseConfig>>('uiResponse', ref({} as EngineResponseConfig));
      const clientsCheckEnabled = computed(() => !!uiResponse.value?.xray?.clients_check);
      const section = ref<SectionId>(props.initialSection || 'connection');
      const navQuery = ref('');
      const profile = ref<ProfileInfo>({
        email: '',
        balance: '— ₽',
        label: 'Основная подписка'
      });

      const navPrimary: NavItem[] = [
        { id: 'account', label: 'Подписка', icon: '◈' },
        { id: 'routing', label: 'Маршрутизация', icon: '⑂' },
        { id: 'network', label: 'Сеть и службы', icon: '◎' },
        { id: 'connection', label: 'Подключение', icon: '⏻' }
      ];
      const navEngine: NavItem[] = [
        { id: 'outbounds', label: 'Исходящие', icon: '⇢' },
        { id: 'engine', label: 'Движок', icon: '◫' }
      ];
      const navMore: NavItem[] = [
        { id: 'logs', label: 'Логи', icon: '▤' },
        { id: 'clients', label: 'Клиенты', icon: '☺' },
        { id: 'updates', label: 'Обновления', icon: '↓' },
        { id: 'help', label: 'Справка', icon: '?' }
      ];

      const allNav = [...navPrimary, ...navEngine, ...navMore];

      const filterNav = (items: NavItem[]) => {
        const q = navQuery.value.trim().toLowerCase();
        if (!q) return items;
        return items.filter((i) => i.label.toLowerCase().includes(q) || i.id.includes(q));
      };

      const filteredPrimary = computed(() => filterNav(navPrimary));
      const filteredEngine = computed(() => filterNav(navEngine));
      const filteredMore = computed(() => filterNav(navMore));

      const currentLabel = computed(() => allNav.find((i) => i.id === section.value)?.label || 'Настройки');
      const needsApply = computed(() => ['routing', 'network', 'outbounds', 'engine'].includes(section.value));

      const setSection = (id: SectionId) => {
        section.value = id;
        emit('section-change', id);
      };

      const onProfile = (info: ProfileInfo) => {
        profile.value = {
          email: info.email || profile.value.email,
          balance: info.balance || profile.value.balance,
          label: info.label || profile.value.label
        };
      };

      const formatRub = (n: number | null | undefined) => {
        if (n == null || Number.isNaN(Number(n))) return '— ₽';
        return `${Number(n).toLocaleString('ru-RU', { maximumFractionDigits: 2 })} ₽`;
      };

      const prefetchProfile = async () => {
        try {
          const bal = await engine.getWebData<{
            keys?: { ok?: boolean; email?: string | null; label?: string; balance?: number | null }[];
            total_balance?: number;
          }>('balances');
          const keys = bal?.data?.keys || [];
          const ok = keys.find((k) => k.ok) || keys[0];
          if (ok) {
            profile.value = {
              email: ok.email || '',
              balance: ok.ok ? formatRub(ok.balance) : formatRub(bal?.data?.total_balance),
              label: ok.label?.trim() || 'Основная подписка'
            };
          } else if (bal?.data?.total_balance != null) {
            profile.value = {
              ...profile.value,
              balance: formatRub(bal.data.total_balance)
            };
          }
        } catch {
          /* optional */
        }
      };

      onMounted(() => {
        void prefetchProfile();
      });

      const emitTransport = (payload: unknown) => emit('show-transport', payload);
      const emitSniffing = (payload: unknown) => emit('show-sniffing', payload);

      return {
        section,
        navQuery,
        profile,
        navPrimary,
        navEngine,
        navMore,
        allNav,
        filteredPrimary,
        filteredEngine,
        filteredMore,
        currentLabel,
        needsApply,
        clientsCheckEnabled,
        setSection,
        onProfile,
        emitTransport,
        emitSniffing
      };
    }
  });
</script>
