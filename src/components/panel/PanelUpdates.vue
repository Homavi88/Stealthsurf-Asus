<template>
  <div class="ss-panel-updates">
    <p class="ss-section-label">Репозиторий</p>
    <div class="ss-set-card">
      <div class="ss-upd-repo">
        <div class="ss-upd-repo__title">GitHub</div>
        <a class="ss-upd-repo__link" :href="repoUrl" target="_blank" rel="noopener">{{ repo }}</a>
        <div class="ss-upd-repo__meta">
          <span>установлено <b>v{{ current }}</b></span>
          <span v-if="displayLatest">latest <b>v{{ displayLatest }}</b></span>
        </div>
        <div class="ss-upd-repo__msg" :class="{ 'is-update': updateAvailable }">
          {{ displayMessage }}
        </div>
        <div class="ss-upd-repo__checked" v-if="status?.checked_at">последняя проверка: {{ checkedLabel }}</div>
        <div class="ss-upd-actions">
          <button
            v-if="updateAvailable && displayLatest"
            type="button"
            class="ss-primary-btn start"
            :disabled="busy"
            @click="installNow"
          >
            Установить v{{ displayLatest }}
          </button>
          <button type="button" class="ss-primary-btn" :class="updateAvailable ? 'ss-upd-check' : 'start'" :disabled="busy" @click="checkNow">
            Проверить сейчас
          </button>
        </div>
      </div>
    </div>

    <p class="ss-section-label">Автопроверка и обновление</p>
    <div class="ss-set-card">
      <ss-settings-row
        title="Автопроверка обновлений"
        :subtitle="checkSubtitle"
        :toggle="checkEnabled"
        @update:toggle="setCheckEnabled"
      >
        <template #detail>
          <label class="ss-field">
            <span>Интервал</span>
            <select v-model="checkInterval">
              <option value="1h">каждый час</option>
              <option value="6h">каждые 6 часов</option>
              <option value="12h">каждые 12 часов</option>
              <option value="24h">раз в сутки</option>
              <option value="3d">каждые 3 дня</option>
              <option value="7d">раз в неделю</option>
            </select>
          </label>
        </template>
      </ss-settings-row>

      <ss-settings-row
        title="Автоустановка"
        subtitle="При новой версии на GitHub — скачать и установить без подтверждения"
        :toggle="!!options.addon_auto_update"
        :divider="false"
        @update:toggle="(v) => (options.addon_auto_update = v)"
      />
    </div>

    <div class="ss-conn-footer">
      <button type="button" class="ss-primary-btn start" :disabled="busy" @click="save">Сохранить</button>
    </div>

    <p class="ss-section-label">Установка вручную</p>
    <div class="ss-set-card ss-upd-manual">
      <p class="ss-upd-manual__hint">Выбор версии и changelog — нажмите на версию ниже:</p>
      <version @install="onManualInstall" />
    </div>

    <panel-update-progress ref="updateProgress" />
  </div>
</template>

<script lang="ts">
  import { computed, defineComponent, inject, onMounted, PropType, Ref, ref, watch } from 'vue';
  import engine, { EngineResponseConfig, SubmitActions } from '@/modules/Engine';
  import { XrayObject } from '@/modules/XrayConfig';
  import useGeneralOptions from '@modal/GeneralOptionsModal';
  import SsSettingsRow from './SsSettingsRow.vue';
  import Version from '../Version.vue';
  import PanelUpdateProgress from './PanelUpdateProgress.vue';
  import { savePanelNav } from './panelNav';
  import { checkSurfGateUpdate, compareVersions, installedVersion, syncDisplayedVersion } from '@/modules/SurfGateUpdate';

  interface UpdateStatus {
    repo?: string;
    current?: string;
    latest?: string;
    update_available?: boolean;
    checked_at?: string;
    message?: string;
  }

  export default defineComponent({
    name: 'PanelUpdates',
    components: { SsSettingsRow, Version, PanelUpdateProgress },
    props: {
      config: { type: Object as PropType<XrayObject>, required: true }
    },
    setup(props) {
      const uiResponse = inject<Ref<EngineResponseConfig>>('uiResponse')!;
      const { options, hydrate, persist } = useGeneralOptions(props.config, uiResponse);
      const busy = ref(false);
      const status = ref<UpdateStatus | null>(null);
      const clientLatest = ref('');
      const clientUpdate = ref(false);
      const checkInterval = ref('24h');
      const updateProgress = ref<{ run: (version?: string) => Promise<void> } | null>(null);

      const repo = computed(() => status.value?.repo || 'Homavi88/Stealthsurf-Asus');
      const repoUrl = computed(() => `https://github.com/${repo.value}/releases`);
      const current = computed(() => {
        const live = installedVersion(uiResponse?.value?.xray?.ui_version);
        const fromStatus = String(status.value?.current || '').replace(/^v/i, '');
        return live || fromStatus || '—';
      });
      const displayLatest = computed(() => clientLatest.value || status.value?.latest || '');
      const updateAvailable = computed(() => {
        const latest = String(displayLatest.value || '').replace(/^v/i, '');
        const cur = String(current.value || '').replace(/^v/i, '');
        if (!latest || !cur || cur === '—') return false;
        return compareVersions(latest, cur) === 1;
      });
      const displayMessage = computed(() => {
        if (updateAvailable.value && displayLatest.value) {
          return `Доступна новая версия: v${displayLatest.value} (установлено v${current.value})`;
        }
        if (clientLatest.value && !updateAvailable.value) {
          return `Актуально (v${current.value})`;
        }
        return status.value?.message || 'Проверка ещё не выполнялась';
      });

      const checkEnabled = computed(() => options.addon_update_check !== 'disabled' && !!options.addon_update_check);
      const checkSubtitle = computed(() =>
        checkEnabled.value
          ? `Интервал: ${options.addon_update_check} · источник GitHub releases`
          : 'Сейчас проверка только при открытии панели / вручную'
      );

      const setCheckEnabled = (on: boolean) => {
        if (on) {
          options.addon_update_check = checkInterval.value || '24h';
        } else {
          if (options.addon_update_check && options.addon_update_check !== 'disabled') {
            checkInterval.value = String(options.addon_update_check);
          }
          options.addon_update_check = 'disabled';
        }
      };

      watch(checkInterval, (v) => {
        if (checkEnabled.value) options.addon_update_check = v;
      });

      const checkedLabel = computed(() => {
        const raw = status.value?.checked_at;
        if (!raw) return '';
        try {
          const d = new Date(raw.endsWith('Z') || raw.includes('+') ? raw : raw.replace(' ', 'T') + 'Z');
          if (!Number.isNaN(d.getTime())) return d.toLocaleString();
        } catch {
          /* ignore */
        }
        return raw;
      });

      const loadStatus = async () => {
        try {
          const res = await engine.getWebData<UpdateStatus>('addon-update-status');
          status.value = res.data || null;
        } catch {
          status.value = null;
        }
      };

      const checkClient = async () => {
        try {
          syncDisplayedVersion(uiResponse?.value?.xray?.ui_version);
          const info = await checkSurfGateUpdate(
            uiResponse?.value?.xray?.ui_version || installedVersion(),
            uiResponse?.value?.xray?.github_proxy
          );
          clientLatest.value = info.latest;
          clientUpdate.value = info.updateAvailable;
          if (info.latest) {
            window.xray.server.stealthsurf_version_latest = info.latest;
          }
        } catch {
          /* router check may still succeed */
        }
      };

      const checkNow = async () => {
        busy.value = true;
        savePanelNav({ view: 'settings', section: 'updates' });
        try {
          await checkClient();
          const prevChecked = status.value?.checked_at || '';
          await engine.submit(SubmitActions.addonUpdateCheck, null, 500);
          // Check no longer writes shared loading progress (raced with Install).
          // Poll status JSON until checked_at moves or timeout.
          for (let i = 0; i < 45; i++) {
            await engine.delay(1000);
            await loadStatus();
            const next = status.value?.checked_at || '';
            if (next && next !== prevChecked) break;
          }
          await checkClient();
        } finally {
          busy.value = false;
        }
      };

      const installNow = async () => {
        const version = String(displayLatest.value || '').replace(/^v/i, '');
        if (!version) return;
        if (!window.confirm(`Установить SurfGate v${version} с GitHub? Роутер скачает пакет и переустановит аддон.`)) {
          return;
        }
        busy.value = true;
        savePanelNav({ view: 'settings', section: 'updates' });
        try {
          // Banner install always pulls GitHub latest (not a pinned stale tag).
          await updateProgress.value?.run('latest');
          await loadStatus();
          await checkClient();
        } finally {
          busy.value = false;
        }
      };

      const onManualInstall = async (version?: string) => {
        busy.value = true;
        savePanelNav({ view: 'settings', section: 'updates' });
        try {
          await updateProgress.value?.run(version);
          await loadStatus();
        } finally {
          busy.value = false;
        }
      };

      const save = async () => {
        if (!uiResponse?.value?.xray) {
          window.alert('Настройки ещё загружаются. Подождите и сохраните снова.');
          return;
        }
        busy.value = true;
        savePanelNav({ view: 'settings', section: 'updates' });
        try {
          await persist('connection');
        } finally {
          busy.value = false;
        }
      };

      const ensureDefaults = () => {
        if (!options.addon_update_check) options.addon_update_check = 'disabled';
        if (typeof options.addon_auto_update !== 'boolean') options.addon_auto_update = false;
        if (options.addon_update_check !== 'disabled') checkInterval.value = String(options.addon_update_check);
      };

      onMounted(() => {
        hydrate();
        ensureDefaults();
        void loadStatus();
        void checkClient();
      });

      watch(
        () => uiResponse?.value,
        () => {
          if (busy.value) return;
          hydrate();
          ensureDefaults();
        },
        { deep: true }
      );

      return {
        options,
        busy,
        status,
        repo,
        repoUrl,
        current,
        displayLatest,
        updateAvailable,
        displayMessage,
        checkEnabled,
        checkSubtitle,
        checkInterval,
        setCheckEnabled,
        checkedLabel,
        checkNow,
        installNow,
        onManualInstall,
        updateProgress,
        save
      };
    }
  });
</script>

<style scoped lang="scss">
  .ss-panel-updates {
    display: flex;
    flex-direction: column;
    gap: 0;
  }

  .ss-upd-repo {
    padding: 14px 16px;
    display: flex;
    flex-direction: column;
    gap: 8px;

    &__title {
      font-size: 11px;
      letter-spacing: 0.08em;
      text-transform: uppercase;
      opacity: 0.55;
    }

    &__link {
      font-family: 'IBM Plex Mono', ui-monospace, monospace;
      font-size: 13px;
      color: var(--ss-accent, #5b9fd4);
      word-break: break-all;
    }

    &__meta {
      display: flex;
      flex-wrap: wrap;
      gap: 12px;
      font-size: 12px;
      opacity: 0.85;

      b {
        font-family: 'IBM Plex Mono', ui-monospace, monospace;
        font-weight: 600;
      }
    }

    &__msg {
      font-size: 13px;
      &.is-update {
        color: #c9a227;
      }
    }

    &__checked {
      font-size: 11px;
      opacity: 0.5;
    }
  }

  .ss-upd-actions {
    margin-top: 4px;
    display: flex;
    flex-direction: column;
    gap: 8px;
  }

  .ss-primary-btn.ss-upd-check {
    background: transparent;
    color: var(--ss-text, #dce8f0);
    border: 1px solid rgba(120, 160, 200, 0.35);
    box-shadow: none;
  }

  .ss-primary-btn.ss-upd-check:hover:not(:disabled) {
    border-color: rgba(120, 160, 200, 0.55);
    filter: brightness(1.05);
  }

  .ss-upd-manual {
    padding: 12px 16px 20px;

    &__hint {
      margin: 0 0 8px;
      font-size: 12px;
      opacity: 0.65;
    }

    :deep(.version) {
      position: relative;
      padding-top: 0;
      a {
        position: static;
        color: var(--ss-accent, #5b9fd4);
        font-size: 13px;
        text-decoration: underline;
      }
    }
  }
</style>
