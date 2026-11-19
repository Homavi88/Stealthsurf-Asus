<template>
  <div>
    <div v-if="xrayuiConflict" class="ss-conflict-banner" role="alert">
      <b>{{ conflictTitle }}</b>
      — {{ conflictMessage }}
    </div>
    <table width="100%" class="FormTable">
      <thead>
        <tr>
          <td colspan="2">
            {{ $t('com.ClientStatus.configuration') }}
            <xray-version class="ss-core-version-inline"></xray-version>
          </td>
        </tr>
      </thead>
      <tbody>
        <tr class="ss-core-version-row">
          <th>Xray-core</th>
          <td>
            <div class="ss-core-version-block">
              <div class="ss-core-version-line">
                <span class="ss-mono">v{{ coreVersionLabel }}</span>
                <span v-if="newerThanTested" class="ss-core-untested" :title="untestedHint">новее тестовой {{ testedCore }}</span>
              </div>
              <button type="button" class="ss-core-version-btn" @click="openCoreVersion">Сменить версию ядра</button>
              <p class="ss-core-version-hint">Список релизов Xray-core с GitHub. SurfGate тестировался с {{ testedCore }}.</p>
            </div>
            <xray-core-version-modal ref="coreVersionModal" v-model:current-version="coreVersionBound" />
          </td>
        </tr>
        <tr>
          <th>{{ $t('com.ClientStatus.connection_status') }}</th>
          <td>
            <span class="label" :class="connectionClasses" v-text="statusLabel"></span>
            <span v-if="xrayuiConflict" class="label label-error ss-conflict-pill">{{ conflictPill }}</span>
            <span v-else-if="xrayuiInstalled" class="label label-warning ss-conflict-pill">{{ $t('com.ClientStatus.xrayui_installed_pill') }}</span>
            <span v-if="!isRunning">
              <a class="button_gen button_gen_small button_info" href="#" @click.prevent="testConfig()" title="try to retrieve a server-side error">!</a>
            </span>
            <span class="row-buttons">
              <a
                v-if="!isRunning"
                class="button_gen button_gen_small"
                :class="{ 'ss-btn-disabled': xrayuiConflict }"
                href="#"
                @click.prevent="handleStatus(connect)"
                >{{ $t('labels.start') }}
              </a>
              <a
                v-if="isRunning"
                class="button_gen button_gen_small"
                :class="{ 'ss-btn-disabled': xrayuiConflict }"
                href="#"
                @click.prevent="handleStatus(reconnect)"
                >{{ $t('labels.restart') }}
              </a>
              <a v-if="isRunning" class="button_gen button_gen_small" href="#" @click.prevent="handleStatus(stop)">{{ $t('labels.stop') }}</a>
              <input class="button_gen button_gen_small" type="button" :value="$t('labels.show_config')" @click.prevent="show_config_modal()" />
            </span>
            <config-modal ref="configModal" />
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
  </div>
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
  import XrayCoreVersionModal from '@modal/XrayCoreVersionModal.vue';
  import { coreNewerThanTested, getTestedCore } from '@/modules/CoreVersion';
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
      XrayCoreVersionModal,
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
      const coreVersionModal = ref<{ show: () => void } | null>(null);
      const coreVersionBound = ref('');
      const testedCore = getTestedCore();
      const newerThanTested = computed(() => coreNewerThanTested());
      const untestedHint = computed(() => t('com.XrayVersion.newer_than_tested_hint', [testedCore]));
      const coreVersionLabel = computed(() => {
        const v = uiResponse?.value?.xray?.core_version || coreVersionBound.value;
        if (v) return String(v).replace(/^v/i, '');
        const err = uiResponse?.value?.xray?.core_error;
        if (err === 'not installed') return t('com.XrayVersion.not_installed');
        if (err) return t('com.XrayVersion.not_working');
        return '—';
      });
      watch(
        () => uiResponse?.value?.xray?.core_version,
        (v) => {
          if (v) coreVersionBound.value = String(v);
        },
        { immediate: true }
      );
      const openCoreVersion = () => {
        coreVersionModal.value?.show();
      };

      const xrayuiConflict = computed(
        () =>
          uiResponse?.value?.conflict === 'xrayui' ||
          uiResponse?.value?.conflict === 'official' ||
          uiResponse?.value?.xrayui?.running === true ||
          uiResponse?.value?.xray?.xrayui?.running === true ||
          uiResponse?.value?.official?.running === true ||
          uiResponse?.value?.xray?.official?.running === true
      );
      const xrayuiInstalled = computed(
        () =>
          (uiResponse?.value?.xrayui?.installed === true || uiResponse?.value?.xray?.xrayui?.installed === true) &&
          !xrayuiConflict.value
      );
      const conflictMessage = computed(() => {
        if (uiResponse?.value?.conflict === 'official') {
          return (
            uiResponse?.value?.conflict_message ||
            uiResponse?.value?.official?.message ||
            uiResponse?.value?.xray?.official?.message ||
            t('com.ClientStatus.official_conflict_message')
          );
        }
        return (
          uiResponse?.value?.conflict_message ||
          uiResponse?.value?.xrayui?.message ||
          uiResponse?.value?.xray?.xrayui?.message ||
          t('com.ClientStatus.xrayui_conflict_message')
        );
      });
      const conflictTitle = computed(() =>
        uiResponse?.value?.conflict === 'official'
          ? t('com.ClientStatus.official_conflict_title')
          : t('com.ClientStatus.xrayui_conflict_title')
      );
      const conflictPill = computed(() =>
        uiResponse?.value?.conflict === 'official'
          ? t('com.ClientStatus.official_conflict_pill')
          : t('com.ClientStatus.xrayui_conflict_pill')
      );

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

      const handleStatus = async (action: string) => {
        if (
          xrayuiConflict.value &&
          (action === SubmitActions.serverStart || action === SubmitActions.serverRestart)
        ) {
          window.alert(conflictMessage.value);
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
        conflictMessage,
        conflictTitle,
        conflictPill,
        show_config_modal,
        manage_general_options,
        testConfig,
        handleStatus,
        coreVersionModal,
        coreVersionBound,
        coreVersionLabel,
        testedCore,
        newerThanTested,
        untestedHint,
        openCoreVersion
      };
    }
  });
</script>
<style scoped>
  .ss-core-version-block {
    display: flex;
    flex-direction: column;
    align-items: flex-start;
    gap: 8px;
  }
  .ss-core-version-line {
    display: flex;
    flex-wrap: wrap;
    align-items: baseline;
    gap: 8px;
    font-family: 'IBM Plex Mono', ui-monospace, monospace;
    font-size: 14px;
  }
  .ss-core-untested {
    color: #ff9a3c;
    font-size: 11px;
  }
  .ss-core-version-btn {
    border: 1px solid rgba(61, 184, 255, 0.45);
    background: rgba(61, 184, 255, 0.14);
    color: #3db8ff;
    border-radius: 6px;
    padding: 8px 12px;
    font-family: 'IBM Plex Mono', ui-monospace, monospace;
    font-size: 12px;
    font-weight: 600;
    cursor: pointer;
  }
  .ss-core-version-hint {
    margin: 0;
    font-size: 11px;
    line-height: 1.35;
    opacity: 0.65;
  }
  .FormTable td span.label.flag {
    margin-left: 5px;
  }
  .ss-conflict-banner {
    margin: 8px 0 12px;
    padding: 10px 12px;
    border: 1px solid #f66;
    background: rgba(255, 68, 68, 0.14);
    color: #ffb3b3;
    font-size: 13px;
    line-height: 1.45;
  }
  .ss-conflict-banner b {
    color: #ff8080;
  }
  .ss-conflict-pill {
    margin-left: 6px;
  }
  .ss-btn-disabled {
    opacity: 0.45;
    cursor: not-allowed;
    pointer-events: none;
  }
</style>
