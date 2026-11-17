<template>
  <div class="ss-set-row" :class="{ 'is-disabled': disabled, 'has-divider': divider }">
    <div class="ss-set-row-main">
      <div class="ss-set-row-text">
        <div class="ss-set-row-title">{{ title }}</div>
        <div v-if="subtitle" class="ss-set-row-sub">{{ subtitle }}</div>
        <slot name="subtitle" />
      </div>
      <div class="ss-set-row-control">
        <ss-toggle
          v-if="withToggle"
          :model-value="!!modelToggle"
          :disabled="disabled || toggleDisabled"
          @update:model-value="onToggle"
        />
        <slot name="control" />
      </div>
    </div>
    <div v-if="$slots.detail && (!withToggle || modelToggle)" class="ss-set-row-detail">
      <fieldset :disabled="disabled || (withToggle && !modelToggle)">
        <slot name="detail" />
      </fieldset>
    </div>
  </div>
</template>

<script lang="ts">
  import { computed, defineComponent } from 'vue';
  import SsToggle from './SsToggle.vue';

  export default defineComponent({
    name: 'SsSettingsRow',
    components: { SsToggle },
    props: {
      title: { type: String, required: true },
      subtitle: { type: String, default: '' },
      /** When provided (incl. false), show an iOS toggle that gates the detail slot. */
      toggle: { type: [Boolean, Number], default: undefined },
      toggleDisabled: { type: Boolean, default: false },
      disabled: { type: Boolean, default: false },
      divider: { type: Boolean, default: true }
    },
    emits: ['update:toggle'],
    setup(props, { emit }) {
      const withToggle = computed(() => props.toggle !== undefined);
      const modelToggle = computed(() => !!props.toggle);
      const onToggle = (v: boolean) => emit('update:toggle', v);
      return { withToggle, modelToggle, onToggle };
    }
  });
</script>
