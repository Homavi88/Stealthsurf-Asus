<template>
  <Teleport to="#stealthsurf-modals">
    <div
      class="xray-modal-overlay"
      :class="{ 'is-panel': variant === 'panel' }"
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
  import { defineComponent, ref, onBeforeUnmount } from 'vue';

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
        type: String as () => 'default' | 'panel',
        default: 'default'
      }
    },
    setup(props, { emit }) {
      const isVisible = ref(false);
      let onCloseCallback: () => void = () => {};

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

    /* SurfGate standalone panel — graphite glass, IBM Plex */
    &.is-panel {
      z-index: 10050;
      padding: 24px 16px;
      background: rgba(5, 8, 12, 0.72);
      -webkit-backdrop-filter: blur(8px);
      backdrop-filter: blur(8px);
      align-items: flex-start;

      .xray-modal-content {
        margin-top: min(8vh, 48px);
        background: linear-gradient(180deg, #151b24 0%, #10151c 100%);
        border: 1px solid rgba(255, 255, 255, 0.1);
        border-radius: 10px;
        box-shadow: 0 24px 64px rgba(0, 0, 0, 0.55);
        padding: 0;
        color: #e6e8eb;
        font-family: 'IBM Plex Sans', 'Segoe UI', sans-serif;
        width: min(520px, 100%);
        max-height: calc(100vh - 3rem);
      }

      .xray-modal-header {
        padding: 16px 18px 10px;
        border-bottom: 1px solid rgba(255, 255, 255, 0.08);

        h2 {
          font-family: 'IBM Plex Sans', 'Segoe UI', sans-serif;
          font-size: 16px;
          font-weight: 600;
          letter-spacing: 0.01em;
          color: #e6e8eb;
        }
      }

      .close-btn {
        width: 32px;
        height: 32px;
        border-radius: 6px;
        color: #8b939e;
        font-size: 22px;
        line-height: 1;

        &:hover {
          background: rgba(255, 255, 255, 0.06);
          color: #e6e8eb;
        }
      }

      .xray-modal-body {
        margin: 0;
        padding: 14px 18px 8px;
        text-align: left;

        :deep(a) {
          color: #3db8ff;
        }
      }

      .xray-modal-footer {
        margin: 0;
        padding: 12px 18px 16px;
        border-top: 1px solid rgba(255, 255, 255, 0.08);

        .row-buttons {
          display: flex;
          flex-direction: column;
          gap: 8px;
          text-align: stretch;
        }

        :deep(.button_gen),
        :deep(input.button_gen) {
          width: 100%;
          margin: 0 !important;
          padding: 12px 14px !important;
          border-radius: 8px !important;
          border: 1px solid rgba(120, 160, 200, 0.35) !important;
          background: transparent !important;
          color: #dce8f0 !important;
          font-family: 'IBM Plex Sans', 'Segoe UI', sans-serif !important;
          font-size: 14px !important;
          font-weight: 500 !important;
          box-shadow: none !important;
          cursor: pointer;
        }

        :deep(.button-primary),
        :deep(input.button-primary) {
          background: linear-gradient(180deg, rgba(61, 184, 255, 0.28), rgba(61, 184, 255, 0.16)) !important;
          border-color: rgba(61, 184, 255, 0.45) !important;
          color: #eaf6ff !important;
        }
      }
    }
  }
</style>
