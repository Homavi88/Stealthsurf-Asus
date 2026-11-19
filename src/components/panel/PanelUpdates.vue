<template>
  <div class="ss-panel-updates">
    <p class="ss-section-label">Репозиторий</p>
    <div class="ss-set-card">
      <div class="ss-upd-repo">
        <div class="ss-upd-repo__title">GitHub</div>
        <a class="ss-upd-repo__link" :href="repoUrl" target="_blank" rel="noopener">{{ repo }}</a>
        <div class="ss-upd-repo__meta">
          <span>установлено <b>v{{ current }}</b></span>
          <span v-if="status?.latest">latest <b>v{{ status.latest }}</b></span>
        </div>
        <div class="ss-upd-repo__msg" :class="{ 'is-update': !!status?.update_available }">
          {{ status?.message || 'Проверка ещё не выполнялась' }}
        </div>
        <div class="ss-upd-repo__checked" v-if="status?.checked_at">последняя проверка: {{ checkedLabel }}</div>
        <div class="ss-upd-actions">
          <button
            v-if="status?.update_available && status?.latest"
            type="button"
            class="ss-primary-btn start"
            :disabled="busy"
            @click="installNow"
          >
            Установить v{{ status.latest }}
          </button>
          <button type="button" class="ss-primary-btn" :class="status?.update_available ? 'ss-upd-check' : 'start'" :disabled="busy" @click="checkNow">
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
      const checkInterval = ref('24h');
      const updateProgress = ref<{ run: (version?: string) => Promise<void> } | null>(null);

      const repo = computed(() => status.value?.repo || 'Homavi88/Stealthsurf-Asus');
      const repoUrl = computed(() => `https://github.com/${repo.value}/releases`);
      const current = computed(
        () =>
          status.value?.current ||
          window.xray?.custom_settings?.stealthsurf_version ||
          uiResponse?.value?.xray?.ui_version ||
          '—'
      );

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

      const checkNow = async () => {
        busy.value = true;
        savePanelNav({ view: 'settings', section: 'updates' });
        try {
          await engine.executeWithLoadingProgress(async () => {
            await engine.submit(SubmitActions.addonUpdateCheck);
          }, false);
          await loadStatus();
        } finally {
          busy.value = false;
        }
      };

      const installNow = async () => {
        const version = status.value?.latest;
        if (!version) return;
        if (!window.confirm(`Установить SurfGate v${version} с GitHub? Роутер скачает пакет и переустановит аддон.`)) {
          return;
        }
        busy.value = true;
        savePanelNav({ view: 'settings', section: 'updates' });
        try {
          await updateProgress.value?.run(version);
          await loadStatus();
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
        loadStatus();
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
