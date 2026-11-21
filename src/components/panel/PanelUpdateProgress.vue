<template>
  <Teleport to="#stealthsurf-modals">
    <div v-if="open" class="ss-upd-overlay" role="dialog" aria-modal="true" aria-labelledby="ss-upd-title">
      <div class="ss-upd-modal" @click.stop>
        <header class="ss-upd-modal__head">
          <h2 id="ss-upd-title">{{ title }}</h2>
        </header>

        <div class="ss-upd-modal__body">
          <p class="ss-upd-modal__ver" v-if="version">
            SurfGate <span class="ss-mono">v{{ version }}</span>
          </p>

          <ol class="ss-upd-stages">
            <li
              v-for="s in stages"
              :key="s.id"
              class="ss-upd-stage"
              :class="{
                'is-done': stageStatus(s.id) === 'done',
                'is-active': stageStatus(s.id) === 'active',
                'is-error': stageStatus(s.id) === 'error',
                'is-pending': stageStatus(s.id) === 'pending'
              }"
            >
              <span class="ss-upd-stage__mark" aria-hidden="true">
                <template v-if="stageStatus(s.id) === 'done'">✓</template>
                <template v-else-if="stageStatus(s.id) === 'error'">!</template>
                <template v-else-if="stageStatus(s.id) === 'active'">
                  <span class="ss-upd-spinner" />
                </template>
                <template v-else>○</template>
              </span>
              <span class="ss-upd-stage__label">{{ s.label }}</span>
            </li>
          </ol>

          <p class="ss-upd-modal__msg" :class="{ 'is-error': phase === 'error', 'is-done': phase === 'done' }">
            {{ displayMessage }}
          </p>

          <div class="ss-upd-bar" v-if="phase === 'running'">
            <div class="ss-upd-bar__fill" :style="{ width: barPct + '%' }" />
          </div>
        </div>

        <footer class="ss-upd-modal__foot" v-if="phase === 'done' || phase === 'error'">
          <p v-if="phase === 'done'" class="ss-upd-modal__hint">Чтобы увидеть новую версию, обновите страницу панели</p>
          <button v-if="phase === 'done'" type="button" class="ss-upd-reload-btn" @click="reloadPanel">
            Обновить страницу
          </button>
          <button v-else type="button" class="ss-upd-reload-btn ss-upd-reload-btn--muted" @click="close">Закрыть</button>
        </footer>
      </div>
    </div>
  </Teleport>
</template>

<script lang="ts">
  import { computed, defineComponent, ref } from 'vue';
  import engine, { EngineLoadingProgress, SubmitActions } from '@/modules/Engine';
  import { savePanelNav } from './panelNav';

  type StageId = 'prepare' | 'download' | 'extract' | 'setup' | 'install' | 'done';
  type StageState = 'pending' | 'active' | 'done' | 'error';
  type Phase = 'idle' | 'running' | 'done' | 'error';

  const STAGE_DEFS: { id: StageId; label: string; match: RegExp }[] = [
    { id: 'prepare', label: 'Подготовка', match: /updat(e|ing)|please.?wait|prepar/i },
    { id: 'download', label: 'Скачивание пакета', match: /download/i },
    { id: 'extract', label: 'Распаковка', match: /extract/i },
    { id: 'setup', label: 'Настройка скрипта', match: /setting up/i },
    { id: 'install', label: 'Установка', match: /running the installation|install/i },
    { id: 'done', label: 'Готово', match: /completed|успеш/i }
  ];

  function matchStage(message: string): StageId | 'error' | null {
    const msg = (message || '').trim();
    if (!msg) return null;
    // Ignore leftover / concurrent GitHub *check* progress (not the install itself).
    if (/update check/i.test(msg) || /github check/i.test(msg)) return null;
    // Only hard install failures — bare "failed" matched check errors and aborted at Подготовка.
    if (
      /^error:/i.test(msg) ||
      /finished with errors/i.test(msg) ||
      /failed to download/i.test(msg) ||
      /could not read the requested version/i.test(msg) ||
      /ошибк/i.test(msg)
    ) {
      return 'error';
    }
    for (let i = STAGE_DEFS.length - 1; i >= 0; i--) {
      if (STAGE_DEFS[i].match.test(msg)) return STAGE_DEFS[i].id;
    }
    return null;
  }

  export default defineComponent({
    name: 'PanelUpdateProgress',
    setup(_props, { expose }) {
      const open = ref(false);
      const version = ref('');
      const phase = ref<Phase>('idle');
      const activeIdx = ref(0);
      const message = ref('');
      const progress = ref(0);

      const stages = STAGE_DEFS;

      const title = computed(() => {
        if (phase.value === 'done') return 'Обновление установлено';
        if (phase.value === 'error') return 'Ошибка обновления';
        return 'Установка обновления';
      });

      const displayMessage = computed(() => message.value || (phase.value === 'running' ? 'Подождите…' : ''));

      const barPct = computed(() => {
        if (progress.value > 0) return Math.min(100, Math.max(4, progress.value));
        return Math.min(92, 8 + activeIdx.value * 18);
      });

      const stageStatus = (id: StageId): StageState => {
        const idx = STAGE_DEFS.findIndex((s) => s.id === id);
        if (phase.value === 'error' && idx === activeIdx.value) return 'error';
        if (phase.value === 'done') return 'done';
        if (idx < activeIdx.value) return 'done';
        if (idx === activeIdx.value && phase.value === 'running') return 'active';
        if (idx === activeIdx.value && phase.value === 'error') return 'error';
        return 'pending';
      };

      const applyProgress = (p: EngineLoadingProgress) => {
        const msg = p?.message || '';
        message.value = msg;
        if (typeof p?.progress === 'number' && p.progress > 0) progress.value = p.progress;

        const hit = matchStage(msg);
        if (hit === 'error') {
          phase.value = 'error';
          return;
        }
        if (!hit) return;
        const idx = STAGE_DEFS.findIndex((s) => s.id === hit);
        if (idx >= 0 && idx >= activeIdx.value) activeIdx.value = idx;
        if (hit === 'done' || (typeof p?.progress === 'number' && p.progress >= 100 && /completed/i.test(msg))) {
          phase.value = 'done';
          activeIdx.value = STAGE_DEFS.length - 1;
        }
      };

      const close = () => {
        if (phase.value === 'running') return;
        open.value = false;
      };

      const reloadPanel = () => {
        savePanelNav({ view: 'home' });
        engine.unloadConfirmed = true;
        // Prefer a clean panel root reload (avoids sticky query junk / broken deep links).
        try {
          const meta = (window as Window & { __SS_PANEL_META__?: { url?: string } }).__SS_PANEL_META__;
          if (meta?.url) {
            const u = new URL(meta.url);
            u.searchParams.set('_sg', String(Date.now()));
            window.location.replace(u.toString());
            return;
          }
          const u = new URL(window.location.href);
          u.search = '';
          u.hash = '';
          u.searchParams.set('_sg', String(Date.now()));
          window.location.replace(u.origin + u.pathname + '?' + u.searchParams.toString());
        } catch {
          window.location.reload();
        }
      };

      const run = async (targetVersion?: string, displayVersion?: string) => {
        open.value = true;
        const raw = (targetVersion || '').replace(/^v/i, '');
        // Backend may get «latest»; show the human version from the banner when provided.
        const shown = (displayVersion || '').replace(/^v/i, '');
        version.value = shown || (raw && raw !== 'latest' ? raw : '');
        phase.value = 'running';
        activeIdx.value = 0;
        message.value = 'Запуск обновления…';
        progress.value = 0;

        const installIdx = STAGE_DEFS.findIndex((s) => s.id === 'install');
        try {
          // Drop stale check/install progress so a previous GitHub check cannot
          // flash «failed» into this modal before performUpdate starts.
          try {
            await engine.submit(SubmitActions.cleanLoadingProgress, null, 0);
          } catch {
            /* optional */
          }

          await engine.executeWithLoadingProgress(
            async () => {
              await engine.submit(
                SubmitActions.performUpdate,
                raw && raw !== 'latest' ? { version: raw } : raw === 'latest' ? { version: 'latest' } : undefined
              );
            },
            false,
            (p) => applyProgress(p)
          );

          if (phase.value === 'running') {
            // Backend cleared loading without an explicit "completed" — treat as success
            // unless the last message looked like an error.
            if (/^error:/i.test(message.value) || /failed/i.test(message.value)) {
              phase.value = 'error';
            } else {
              phase.value = 'done';
              activeIdx.value = STAGE_DEFS.length - 1;
              if (!message.value || /please.?wait/i.test(message.value)) {
                message.value = 'Update process completed!';
              }
            }
          }
        } catch (e) {
          // Install restarts panel-httpd; progress polls can time out after the
          // package is already applied. Prefer "reload to verify" over a hard fail
          // only once we reached the install stage — earlier disconnects are real errors.
          if (activeIdx.value >= installIdx && installIdx >= 0) {
            phase.value = 'done';
            activeIdx.value = STAGE_DEFS.length - 1;
            message.value =
              'Пакет установлен, панель перезапускалась. Нажмите «Обновить страницу» — баннер исчезнет, если версия применилась.';
          } else {
            phase.value = 'error';
            message.value = e instanceof Error ? e.message : 'Ошибка при установке обновления';
          }
        }
      };

      expose({ run, close });

      return {
        open,
        version,
        phase,
        stages,
        title,
        displayMessage,
        barPct,
        stageStatus,
        close,
        reloadPanel
      };
    }
  });
</script>

<style scoped lang="scss">
  .ss-upd-overlay {
    position: fixed;
    inset: 0;
    z-index: 10050;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 24px 16px;
    background: rgba(28, 52, 84, 0.28);
    -webkit-backdrop-filter: blur(10px);
    backdrop-filter: blur(10px);
  }

  .ss-upd-modal {
    width: min(420px, 100%);
    border-radius: 16px;
    border: 1px solid rgba(28, 52, 84, 0.1);
    background: #ffffff;
    box-shadow: 0 16px 48px rgba(28, 52, 84, 0.18);
    color: #1c2430;
    font-family: 'Manrope', 'Segoe UI', sans-serif;
    overflow: hidden;
  }

  .ss-upd-modal__head {
    padding: 18px 20px 8px;

    h2 {
      margin: 0;
      font-size: 17px;
      font-weight: 750;
      letter-spacing: -0.02em;
    }
  }

  .ss-upd-modal__body {
    padding: 8px 20px 16px;
  }

  .ss-upd-modal__ver {
    margin: 0 0 14px;
    font-size: 13px;
    color: #7a8696;

    .ss-mono {
      font-family: 'IBM Plex Mono', ui-monospace, monospace;
      color: #2f6fed;
    }
  }

  .ss-upd-stages {
    list-style: none;
    margin: 0;
    padding: 0;
    display: flex;
    flex-direction: column;
    gap: 10px;
  }

  .ss-upd-stage {
    display: flex;
    align-items: center;
    gap: 12px;
    font-size: 13px;
    opacity: 0.4;
    transition: opacity 0.2s ease;

    &.is-active,
    &.is-done {
      opacity: 1;
    }

    &.is-error {
      opacity: 1;
      color: #e04848;
    }

    &.is-done .ss-upd-stage__mark {
      color: #1f9d5c;
    }

    &.is-active .ss-upd-stage__label {
      font-weight: 650;
    }
  }

  .ss-upd-stage__mark {
    width: 22px;
    height: 22px;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    font-family: 'IBM Plex Mono', ui-monospace, monospace;
    font-size: 12px;
    flex-shrink: 0;
  }

  .ss-upd-spinner {
    width: 14px;
    height: 14px;
    border: 2px solid rgba(47, 111, 237, 0.2);
    border-top-color: #2f6fed;
    border-radius: 50%;
    animation: ss-upd-spin 0.7s linear infinite;
  }

  @keyframes ss-upd-spin {
    to {
      transform: rotate(360deg);
    }
  }

  .ss-upd-modal__msg {
    margin: 16px 0 0;
    min-height: 2.4em;
    font-size: 12px;
    font-family: 'IBM Plex Mono', ui-monospace, monospace;
    color: #7a8696;
    line-height: 1.4;
    word-break: break-word;

    &.is-error {
      color: #e04848;
    }

    &.is-done {
      color: #1f9d5c;
    }
  }

  .ss-upd-bar {
    margin-top: 12px;
    height: 6px;
    border-radius: 999px;
    background: rgba(28, 52, 84, 0.08);
    overflow: hidden;

    &__fill {
      height: 100%;
      border-radius: inherit;
      background: linear-gradient(90deg, #4d8af5, #2f6fed);
      transition: width 0.35s ease;
    }
  }

  .ss-upd-modal__hint {
    margin: 0 0 4px;
    font-size: 12px;
    line-height: 1.35;
    color: #7a8696;
  }

  .ss-upd-modal__foot {
    padding: 0 20px 18px;
    display: flex;
    flex-direction: column;
    gap: 8px;
  }

  .ss-upd-reload-btn {
    width: 100%;
    box-sizing: border-box;
    border: 0;
    border-radius: 12px;
    padding: 14px 16px;
    font-family: 'Manrope', 'Segoe UI', sans-serif;
    font-size: 14px;
    font-weight: 700;
    letter-spacing: 0;
    text-transform: none;
    cursor: pointer;
    background: #2f6fed;
    color: #fff;
    box-shadow: 0 10px 24px rgba(47, 111, 237, 0.22);
  }

  .ss-upd-reload-btn:active {
    filter: brightness(0.97);
  }

  .ss-upd-reload-btn--muted {
    background: #fff;
    color: #2f6fed;
    border: 1px solid rgba(47, 111, 237, 0.22);
    box-shadow: none;
  }
</style>
