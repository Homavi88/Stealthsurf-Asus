<template>
  <table width="100%" class="FormTable">
    <thead>
      <tr>
        <td colspan="2">
          {{ $t('com.ClientStatus.configuration') }}
          <xray-version></xray-version>
        </td>
      </tr>
    </thead>
    <tbody>
      <tr>
        <th>{{ $t('com.ClientStatus.connection_status') }}</th>
        <td>
          <span class="label" :class="connectionClasses" v-text="statusLabel"></span>
          <span v-if="xrayuiConflict" class="label label-error">{{ $t('com.ClientStatus.xrayui_conflict') }}</span>
          <span v-else-if="xrayuiInstalled" class="label label-warning">{{ $t('com.ClientStatus.xrayui_installed') }}</span>
          <span v-if="!isRunning">
            <a class="button_gen button_gen_small button_info" href="#" @click.prevent="testConfig()" title="try to retrieve a server-side error">!</a>
          </span>
          <span class="row-buttons">
            <a v-if="!isRunning" class="button_gen button_gen_small" href="#" @click.prevent="handleStatus(connect)">{{ $t('labels.start') }} </a>
            <a v-if="isRunning" class="button_gen button_gen_small" href="#" @click.prevent="handleStatus(reconnect)">{{ $t('labels.restart') }} </a>
            <a v-if="isRunning" class="button_gen button_gen_small" href="#" @click.prevent="handleStatus(stop)">{{ $t('labels.stop') }}</a>
            <input class="button_gen button_gen_small" type="button" :value="$t('labels.show_config')" @click.prevent="show_config_modal()" />
          </span>
          <config-modal ref="configModal" />
          <div v-if="xrayuiConflict" class="ss-conflict-banner">
            <b>{{ $t('com.ClientStatus.xrayui_conflict') }}</b> — {{ xrayuiMessage }}
          </div>
        </td>
      </tr>
      <profiles />
      <process-uptime />
      <import-config v-model:config="config" />
      <tr>
        <th>{{ $t('com.ClientStatus.general_options') }}</th>
        <td>
          <span class="row-buttons">
            <input class="button_gen button_gen_small" type="button" :value="$t('labels.manage')" @click.prevent="manage_general_options()" v-show="uiResponse?.xray" />
          </span>
          <general-options-modal ref="generalOptionsModal" v-model:config="config"></general-options-modal>
        </td>
      </tr>
      <backup />
    </tbody>
  </table>
</template>

<script lang="ts">
  import { defineComponent, ref, computed, inject, Ref, watch } from 'vue';
  import engine, { EngineResponseConfig, SubmitActions } from '@/modules/Engine';
  import GeneralOptionsModal from '@modal/GeneralOptionsModal.vue';
  import ImportConfig from './ImportConfig.vue';
  import { XrayObject } from '@/modules/XrayConfig';
  import ConfigModal from '@modal/ConfigModal.vue';
  import { useI18n } from 'vue-i18n';
  import ProcessUptime from './ProcessUptime.vue';
  import XrayVersion from './XrayVersion.vue';
  import Profiles from './Profiles.vue';
  import Backup from './Backup.vue';

  export default defineComponent({
    name: 'ServiceStatus',
    components: {
      GeneralOptionsModal,
      ImportConfig,
      ConfigModal,
      ProcessUptime,
      XrayVersion,
      Profiles,
      Backup
    },
    props: {
      config: {
        type: XrayObject,
        required: true
      }
    },
    computed: {
      statusLabel(): string {
        return this.isRunning ? this.$t('com.ClientStatus.xray_running') : this.$t('com.ClientStatus.xray_stopped');
      }
    },
    setup(props) {
      const { t } = useI18n();
      const config = ref(props.config);
      const configModal = ref();
      const generalOptionsModal = ref();
      const connectionStationLabel = ref<string>(t('com.ClientStatus.xray_running'));
      const connectionClasses = computed(() => ({
        'label-success': isRunning.value,
        'label-error': !isRunning.value
      }));

      const uiResponse = inject<Ref<EngineResponseConfig>>('uiResponse')!;

      // Prefer StealthSurf-owned running state from backend (uptime/running), not Merlin pid.xray
      // which also matches stock XrayUI and makes Start/Stop look like no-ops.
      const isRunning = ref<boolean>(window.xray.server.isRunning);
      watch(
        () => [uiResponse?.value?.xray?.running, uiResponse?.value?.xray?.uptime] as const,
        ([running, uptime]) => {
          if (typeof running === 'boolean') {
            isRunning.value = running;
            window.xray.server.isRunning = running;
          } else if (typeof uptime === 'number') {
            const next = uptime > 0;
            isRunning.value = next;
            window.xray.server.isRunning = next;
          }
        },
        { immediate: true }
      );

      const show_config_modal = () => {
        configModal.value.show();
      };

      const manage_general_options = () => {
        generalOptionsModal.value.show();
      };

      const testConfig = async () => {
        let delay = 1000;
        window.showLoading(delay);
        await engine.submit(SubmitActions.serverTestConfig, null, delay);
        let users = await engine.getXrayResponse();
        window.hideLoading();
        alert(users.xray?.test.replace(/\\"/g, '"'));
      };

      const xrayuiConflict = computed(() => !!uiResponse.value?.xray?.xrayui?.running || uiResponse.value?.xray?.xrayui?.conflict === 'xrayui');
      const xrayuiInstalled = computed(() => !!uiResponse.value?.xray?.xrayui?.installed);
      const xrayuiMessage = computed(() => uiResponse.value?.xray?.xrayui?.message || t('com.ClientStatus.xrayui_conflict_banner'));

      const handleStatus = async (action: string) => {
        if (action === SubmitActions.serverStart && xrayuiConflict.value) {
          alert(xrayuiMessage.value);
          return;
        }
        if (engine.hasUnappliedChanges(config.value) && !window.confirm(t('com.ClientStatus.confirm_unapplied_changes'))) return;
        await engine.executeWithLoadingProgress(async () => {
          await engine.submit(action);
        });
      };

      return {
        config,
        configModal,
        isRunning,
        connectionClasses,
        connectionStationLabel,
        generalOptionsModal,
        connect: SubmitActions.serverStart,
        reconnect: SubmitActions.serverRestart,
        stop: SubmitActions.serverStop,
        uiResponse,
        xrayuiConflict,
        xrayuiInstalled,
        xrayuiMessage,
        show_config_modal,
        manage_general_options,
        testConfig,
        handleStatus
      };
    }
  });
</script>
<style scoped>
  .FormTable td span.label.flag {
    margin-left: 5px;
  }
  .ss-conflict-banner {
    margin-top: 8px;
    padding: 8px 10px;
    border-radius: 4px;
    background: #5a2a2a;
    color: #ffb0b0;
    line-height: 1.4;
  }
  .ss-conflict-banner b {
    color: #ff8080;
  }
</style>
