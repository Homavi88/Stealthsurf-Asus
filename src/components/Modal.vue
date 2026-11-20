<template>
  <Teleport to="#stealthsurf-modals">
    <div
      class="xray-modal-overlay"
      :class="{ 'is-panel': isPanel }"
      v-if="isVisible"
      @mousedown.self="close"
      role="dialog"
      aria-modal="true"
    >
      <div class="xray-modal-content" @click.stop :style="{ width }">
        <header class="xray-modal-header">
          <h2>
            <slot name="title">
              {{ title }}
            </slot>
          </h2>
          <button class="close-btn" type="button" @click="close" aria-label="Close modal">×</button>
        </header>
        <div class="xray-modal-body">
          <slot></slot>
        </div>
        <footer class="xray-modal-footer">
          <span class="row-buttons">
            <slot name="footer">
              <button type="button" @click.prevent="close" class="button_gen button_gen_small">
                {{ $t('labels.close') }}
              </button>
            </slot>
          </span>
        </footer>
      </div>
    </div>
  </Teleport>
</template>

<script lang="ts">
  import { computed, defineComponent, ref, onBeforeUnmount } from 'vue';

  export default defineComponent({
    name: 'Modal',
    emits: ['close'],
    props: {
      title: {
        type: String,
        default: 'Modal Title'
      },
      width: {
        type: String,
        default: '755'
      },
      variant: {
        type: String as () => 'default' | 'panel' | 'auto',
        default: 'auto'
      }
    },
    setup(props, { emit }) {
      const isVisible = ref(false);
      let onCloseCallback: () => void = () => {};

      const isPanel = computed(() => {
        if (props.variant === 'panel') return true;
        if (props.variant === 'default') return false;
        return Boolean((window as Window & { __SS_PANEL__?: boolean }).__SS_PANEL__);
      });

      const show = (onClose?: () => void) => {
        isVisible.value = true;
        if (onClose) onCloseCallback = onClose;
        document.addEventListener('keydown', handleKeyDown);
      };

      const close = () => {
        isVisible.value = false;
        emit('close');
        if (typeof onCloseCallback === 'function') {
          onCloseCallback();
        }
        document.removeEventListener('keydown', handleKeyDown);
      };

      const handleKeyDown = (event: KeyboardEvent) => {
        if (event.key === 'Escape') {
          close();
        }
      };

      onBeforeUnmount(() => {
        document.removeEventListener('keydown', handleKeyDown);
      });

      return {
        isVisible,
        isPanel,
        show,
        close,
        width: props.width.endsWith('%') ? props.width : `${props.width.replace('px', '')}px`
      };
    }
  });
</script>
<style scoped lang="scss">
  .xray-modal-overlay {
    position: fixed;
    top: 0;
    left: 0;
    width: 100%;
    height: 100%;
    background-color: rgba(0, 0, 0, 0.5);
    backdrop-filter: blur(6px);
    z-index: 400;

    display: flex;
    justify-content: center;
    overflow-y: auto;
    padding: 2rem 1rem;
    align-items: center;

    &:not(:last-child) {
      background-color: rgba(0, 0, 0, 0) !important;
      backdrop-filter: initial !important;
    }

    .xray-modal-content {
      background-color: #4d595d;
      border-radius: 5px;
      max-width: 100%;
      padding: 5px;
      position: relative;
      border: 1px solid #222;

      width: clamp(320px, var(--modal-width, 755px), 90vw);
      max-height: calc(100vh - 4rem);
      overflow-y: auto;

      .xray-modal-header {
        display: flex;
        justify-content: space-between;
        align-items: center;
        padding-left: 5px;
        font-weight: bold;
        line-height: 140%;
        color: #ffffff;

        h2 {
          margin: 0;
        }
      }
    }

    .close-btn {
      background: none;
      border: none;
      font-size: 1.5rem;
      cursor: pointer;
      color: inherit;
    }

    .xray-modal-body {
      text-align: center;
      margin-top: 10px;

      :deep(a) {
        color: #ffcc00;
        text-decoration: underline;
      }

      :deep(.modal-form-table) {
        width: 100%;

        td {
          text-align: left;
        }
      }
    }

    .xray-modal-footer {
      margin-top: 20px;
      text-align: center;

      .row-buttons {
        width: 100%;
        text-align: right;
      }
    }

    /* SurfGate standalone panel — light soft UI (matches panelTheme) */
    &.is-panel {
      --ss-text: #1c2430;
      --ss-muted: #7a8696;
      --ss-line: rgba(28, 52, 84, 0.1);
      --ss-hair: rgba(28, 52, 84, 0.06);
      --ss-blue: #2f6fed;
      --ss-blue-soft: rgba(47, 111, 237, 0.12);
      --ss-danger: #e04848;
      --ss-font: 'Manrope', 'Segoe UI', 'Helvetica Neue', sans-serif;
      --ss-font-mono: 'IBM Plex Mono', ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;

      z-index: 10050;
      padding: max(16px, env(safe-area-inset-top, 0px)) 16px max(16px, env(safe-area-inset-bottom, 0px));
      background: rgba(28, 52, 84, 0.28);
      -webkit-backdrop-filter: blur(10px);
      backdrop-filter: blur(10px);
      align-items: flex-start;

      .xray-modal-content {
        margin-top: min(6vh, 36px);
        background: #ffffff;
        border: 1px solid var(--ss-line);
        border-radius: 16px;
        box-shadow: 0 16px 48px rgba(28, 52, 84, 0.18);
        padding: 0;
        color: var(--ss-text);
        font-family: var(--ss-font);
        width: min(520px, 100%);
        max-height: calc(100vh - 3rem);
      }

      .xray-modal-header {
        padding: 16px 18px 12px;
        border-bottom: 1px solid var(--ss-hair);
        color: var(--ss-text);

        h2 {
          font-family: var(--ss-font);
          font-size: 17px;
          font-weight: 750;
          letter-spacing: -0.02em;
          color: var(--ss-text);
        }
      }

      .close-btn {
        width: 34px;
        height: 34px;
        border-radius: 10px;
        color: var(--ss-muted);
        font-size: 22px;
        line-height: 1;

        &:hover {
          background: rgba(47, 111, 237, 0.08);
          color: var(--ss-blue);
        }
      }

      .xray-modal-body {
        margin: 0;
        padding: 14px 18px 8px;
        text-align: left;
        color: var(--ss-text);

        :deep(a) {
          color: var(--ss-blue);
        }

        :deep(.formfontdesc),
        :deep(.formfontdesc p) {
          color: var(--ss-muted);
          font-family: var(--ss-font);
          font-size: 13px;
          line-height: 1.45;
        }

        :deep(.FormTable),
        :deep(table.FormTable),
        :deep(.modal-form-table) {
          width: 100%;
          border-collapse: collapse;
          border-spacing: 0;
          background: transparent;
          border: 0;
          margin: 10px 0 0;
        }

        :deep(.FormTable th),
        :deep(.FormTable td),
        :deep(.modal-form-table th),
        :deep(.modal-form-table td) {
          background: transparent !important;
          color: var(--ss-text) !important;
          border: 0 !important;
          border-bottom: 1px solid var(--ss-hair) !important;
          padding: 12px 0 !important;
          vertical-align: top;
          text-align: left;
          font-family: var(--ss-font);
        }

        :deep(.FormTable th),
        :deep(.modal-form-table th) {
          width: 34%;
          font-weight: 650;
          font-size: 13px;
          color: var(--ss-muted) !important;
          padding-right: 12px !important;
        }

        :deep(.FormTable tr:last-child th),
        :deep(.FormTable tr:last-child td),
        :deep(.modal-form-table tr:last-child th),
        :deep(.modal-form-table tr:last-child td) {
          border-bottom: 0 !important;
        }

        :deep(select),
        :deep(input[type='text']),
        :deep(input[type='number']),
        :deep(input[type='password']),
        :deep(textarea),
        :deep(.input_option),
        :deep(.input_25_table),
        :deep(.input_32_table) {
          width: 100%;
          max-width: 100%;
          box-sizing: border-box;
          background: #f5f7fa !important;
          border: 1px solid var(--ss-line) !important;
          border-radius: 12px !important;
          color: var(--ss-text) !important;
          font-family: var(--ss-font) !important;
          font-size: 14px !important;
          font-weight: 500 !important;
          padding: 11px 12px !important;
          outline: none;
          box-shadow: none !important;
        }

        :deep(select:focus),
        :deep(input:focus),
        :deep(textarea:focus) {
          border-color: rgba(47, 111, 237, 0.4) !important;
          box-shadow: 0 0 0 3px rgba(47, 111, 237, 0.16) !important;
        }

        :deep(.hint),
        :deep(.hint-color),
        :deep(.hint-color a) {
          color: var(--ss-muted) !important;
          float: none !important;
          font-weight: 500 !important;
          font-style: normal !important;
        }

        :deep(.current-version strong) {
          color: var(--ss-blue) !important;
          font-family: var(--ss-font-mono) !important;
        }

        :deep(.prerelease-tag) {
          color: #c47a00 !important;
          font-weight: 650 !important;
        }

        :deep(.button_gen),
        :deep(input.button_gen),
        :deep(button.button_gen) {
          background: var(--ss-blue-soft) !important;
          color: var(--ss-blue) !important;
          border: 1px solid rgba(47, 111, 237, 0.22) !important;
          border-radius: 10px !important;
          font-family: var(--ss-font) !important;
          font-weight: 650 !important;
          box-shadow: none !important;
          cursor: pointer;
        }
      }

      .xray-modal-footer {
        margin: 0;
        padding: 12px 18px 16px;
        border-top: 1px solid var(--ss-hair);

        .row-buttons {
          display: flex;
          flex-direction: column;
          gap: 8px;
          text-align: stretch;
        }

        :deep(.button_gen),
        :deep(input.button_gen),
        :deep(button.button_gen) {
          width: 100%;
          margin: 0 !important;
          padding: 13px 14px !important;
          border-radius: 12px !important;
          border: 1px solid rgba(47, 111, 237, 0.22) !important;
          background: var(--ss-blue) !important;
          color: #fff !important;
          font-family: var(--ss-font) !important;
          font-size: 14px !important;
          font-weight: 700 !important;
          letter-spacing: 0 !important;
          text-transform: none !important;
          box-shadow: 0 10px 24px rgba(47, 111, 237, 0.22) !important;
          cursor: pointer;
        }

        :deep(.button_gen:disabled),
        :deep(input.button_gen:disabled) {
          opacity: 0.45 !important;
          cursor: not-allowed !important;
          box-shadow: none !important;
        }
      }
    }
  }

  @media (max-width: 860px) {
    .xray-modal-overlay.is-panel {
      .xray-modal-content {
        margin-top: 8px;
        border-radius: 18px;
        width: 100%;
      }

      .xray-modal-header {
        padding: 14px 14px 10px;
      }

      .xray-modal-body {
        padding: 12px 14px 6px;

        :deep(.FormTable),
        :deep(.modal-form-table),
        :deep(.FormTable tbody),
        :deep(.FormTable tr),
        :deep(.modal-form-table tbody),
        :deep(.modal-form-table tr) {
          display: block;
          width: 100%;
        }

        :deep(.FormTable th),
        :deep(.FormTable td),
        :deep(.modal-form-table th),
        :deep(.modal-form-table td) {
          display: block;
          width: 100% !important;
          padding: 6px 0 !important;
          border-bottom: 0 !important;
        }

        :deep(.FormTable th),
        :deep(.modal-form-table th) {
          padding-bottom: 2px !important;
          font-size: 12px;
        }

        :deep(.FormTable td),
        :deep(.modal-form-table td) {
          padding-bottom: 14px !important;
          border-bottom: 1px solid var(--ss-hair) !important;
        }

        :deep(.FormTable tr:last-child td),
        :deep(.modal-form-table tr:last-child td) {
          border-bottom: 0 !important;
          padding-bottom: 4px !important;
        }
      }

      .xray-modal-footer {
        padding: 12px 14px 14px;
      }
    }
  }
</style>
