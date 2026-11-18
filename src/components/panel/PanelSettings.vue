<template>
  <div>
    <button type="button" class="ss-back-link" @click="$emit('back')">← home</button>
    <h2 class="ss-settings-title">settings</h2>

    <div class="ss-settings-layout">
      <aside>
        <div class="ss-nav-group">
          <button
            v-for="item in navPrimary"
            :key="item.id"
            type="button"
            class="ss-nav-item"
            :class="{ 'is-active': section === item.id }"
            @click="section = item.id"
          >
            <span class="ss-nav-ico">{{ item.icon }}</span>
            {{ item.label }}
          </button>
        </div>
        <div class="ss-nav-group">
          <button
            v-for="item in navEngine"
            :key="item.id"
            type="button"
            class="ss-nav-item"
            :class="{ 'is-active': section === item.id }"
            @click="section = item.id"
          >
            <span class="ss-nav-ico">{{ item.icon }}</span>
            {{ item.label }}
          </button>
        </div>
        <div class="ss-nav-group">
          <button
            v-for="item in navMore"
            :key="item.id"
            type="button"
            class="ss-nav-item"
            :class="{ 'is-active': section === item.id }"
            @click="section = item.id"
          >
            <span class="ss-nav-ico">{{ item.icon }}</span>
            {{ item.label }}
          </button>
        </div>
      </aside>

      <section class="ss-settings-pane" :class="{ 'is-native': section === 'connection' || section === 'account' }">
        <h2 class="ss-pane-heading">{{ currentLabel }}</h2>

        <div v-if="section === 'account'" class="ss-panel-light">
          <stealth-surf-account />
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
          <clients-online />
        </div>

        <div v-else-if="section === 'updates'" class="ss-panel-light">
          <panel-updates :config="config" />
        </div>

        <div class="ss-apply-wrap" v-if="needsApply">
          <button type="button" class="ss-primary-btn start" @click.prevent="$emit('apply')">apply</button>
        </div>
      </section>
    </div>
  </div>
</template>

<script lang="ts">
  import { computed, defineComponent, PropType, ref } from 'vue';
  import { XrayObject } from '@/modules/XrayConfig';
  import StealthSurfAccount from '../StealthSurfAccount.vue';
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

  type SectionId =
    | 'account'
    | 'connection'
    | 'routing'
    | 'network'
    | 'outbounds'
    | 'engine'
    | 'logs'
    | 'clients'
    | 'updates';

  export default defineComponent({
    name: 'PanelSettings',
    components: {
      StealthSurfAccount,
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
      PanelConnection
    },
    props: {
      config: { type: Object as PropType<XrayObject>, required: true }
    },
    emits: ['back', 'apply', 'show-transport', 'show-sniffing'],
    setup(_props, { emit }) {
      const section = ref<SectionId>('connection');
      const navPrimary = [
        { id: 'account' as const, label: 'account', icon: 'A' },
        { id: 'connection' as const, label: 'connection', icon: 'C' },
        { id: 'routing' as const, label: 'routing', icon: 'R' },
        { id: 'network' as const, label: 'network', icon: 'N' }
      ];
      const navEngine = [
        { id: 'outbounds' as const, label: 'outbounds', icon: 'O' },
        { id: 'engine' as const, label: 'engine', icon: 'E' }
      ];
      const navMore = [
        { id: 'logs' as const, label: 'logs', icon: 'L' },
        { id: 'clients' as const, label: 'clients', icon: 'U' },
        { id: 'updates' as const, label: 'updates', icon: 'V' }
      ];

      const all = [...navPrimary, ...navEngine, ...navMore];
      const currentLabel = computed(() => all.find((i) => i.id === section.value)?.label || 'settings');
      // Connection has its own Save; avoid double Apply
      const needsApply = computed(() => ['routing', 'network', 'outbounds', 'engine'].includes(section.value));

      const emitTransport = (payload: unknown) => emit('show-transport', payload);
      const emitSniffing = (payload: unknown) => emit('show-sniffing', payload);

      return {
        section,
        navPrimary,
        navEngine,
        navMore,
        currentLabel,
        needsApply,
        emitTransport,
        emitSniffing
      };
    }
  });
</script>
