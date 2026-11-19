<template>
  <div class="ss-help">
    <div class="ss-help-toolbar">
      <a class="ss-chip-btn" :href="helpUrl" target="_blank" rel="noopener">Открыть в новой вкладке</a>
      <span class="ss-help-hint">Установка · настройки · CLI · backup · скриншоты</span>
    </div>
    <iframe class="ss-help-frame" :src="helpUrl" title="Справка SurfGate" />
  </div>
</template>

<script lang="ts">
  import { defineComponent } from 'vue';

  export default defineComponent({
    name: 'PanelHelp',
    setup() {
      // Served from the panel webroot as /help/index.html (packaged next to app.js).
      const helpUrl = './help/index.html';
      return { helpUrl };
    }
  });
</script>

<style scoped>
  .ss-help {
    display: flex;
    flex-direction: column;
    gap: 0.75rem;
    min-height: min(75vh, 820px);
  }
  .ss-help-toolbar {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 0.75rem 1rem;
  }
  .ss-help-hint {
    color: var(--ss-muted, #8b939e);
    font-size: 0.88rem;
  }
  .ss-help-frame {
    flex: 1;
    width: 100%;
    min-height: min(70vh, 780px);
    border: 1px solid var(--ss-line, rgba(255, 255, 255, 0.09));
    border-radius: 4px;
    background: #0c1014;
  }
</style>
