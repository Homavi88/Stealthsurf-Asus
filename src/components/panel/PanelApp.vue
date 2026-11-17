<template>
  <div class="ss-panel-root">
    <div class="ss-panel-shell" :class="{ 'ss-settings-wide': view === 'settings' }">
      <panel-home v-if="view === 'home'" @open-settings="view = 'settings'" />
      <panel-settings
        v-else
        :config="config"
        @back="view = 'home'"
        @apply="apply_settings"
        @show-transport="show_transport"
        @show-sniffing="show_sniffing"
      />
    </div>
    <sniffing-modal ref="sniffingModal" />
    <stream-settings-modal ref="transportModal" />
  </div>
</template>

<script lang="ts">
  import { defineComponent, onBeforeUnmount, onMounted, ref, watch } from 'vue';
  import { useI18n } from 'vue-i18n';
  import engine, { SubmitActions } from '@/modules/Engine';
  import { ApplyCheckError, checkBeforeApply } from '@/modules/ApplyChecks';
  import { IProtocolType } from '@/modules/Interfaces';
  import { XrayInboundObject } from '@/modules/InboundObjects';
  import { XrayOutboundObject } from '@/modules/OutboundObjects';
  import PanelHome from './PanelHome.vue';
  import PanelSettings from './PanelSettings.vue';
  import SniffingModal from '@modal/SniffingModal.vue';
  import StreamSettingsModal from '@modal/StreamSettingsModal.vue';
  import './panelTheme.scss';

  export default defineComponent({
    name: 'PanelApp',
    components: { PanelHome, PanelSettings, SniffingModal, StreamSettingsModal },
    setup() {
      const { t } = useI18n();
      const view = ref<'home' | 'settings'>('home');
      const config = ref(engine.xrayConfig);
      const sniffingModal = ref();
      const transportModal = ref();
      let timer: ReturnType<typeof setInterval> | undefined;

      const syncConfig = () => {
        config.value = engine.xrayConfig;
      };

      onMounted(() => {
        if (typeof window.hideLoading === 'function') window.hideLoading();
        const loading = document.getElementById('Loading');
        if (loading) {
          loading.style.visibility = 'hidden';
          loading.style.display = 'none';
          loading.style.pointerEvents = 'none';
        }
        syncConfig();
        timer = window.setInterval(() => {
          if (engine.xrayConfig !== config.value) syncConfig();
        }, 1500);
      });

      onBeforeUnmount(() => {
        if (timer) clearInterval(timer);
      });

      watch(
        () => engine.xrayConfig,
        () => syncConfig()
      );

      const show_transport = async (obj: XrayInboundObject<IProtocolType> | XrayOutboundObject<IProtocolType>) => {
        await transportModal.value.show(obj);
      };

      const show_sniffing = async (inbound: XrayInboundObject<IProtocolType>) => {
        await sniffingModal.value.show(inbound);
      };

      const apply_settings = async () => {
        try {
          checkBeforeApply(config.value);
        } catch (e) {
          if (e instanceof ApplyCheckError) {
            window.alert(e.message);
            return;
          }
          throw e;
        }
        await engine.executeWithLoadingProgress(async () => {
          await engine.submit(SubmitActions.configurationApply, config.value);
        });
        window.alert(t('labels.apply') || 'Applied');
      };

      return {
        view,
        config,
        sniffingModal,
        transportModal,
        show_transport,
        show_sniffing,
        apply_settings
      };
    }
  });
</script>
