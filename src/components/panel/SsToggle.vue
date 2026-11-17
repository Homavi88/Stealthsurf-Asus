<template>
  <button
    type="button"
    class="ss-toggle"
    role="switch"
    :aria-checked="modelValue ? 'true' : 'false'"
    :aria-disabled="disabled ? 'true' : 'false'"
    :disabled="disabled"
    :class="{ 'is-on': modelValue, 'is-disabled': disabled }"
    @click="onClick"
  >
    <span class="ss-toggle-thumb" aria-hidden="true"></span>
  </button>
</template>

<script lang="ts">
  import { defineComponent } from 'vue';

  export default defineComponent({
    name: 'SsToggle',
    props: {
      modelValue: { type: Boolean, default: false },
      disabled: { type: Boolean, default: false }
    },
    emits: ['update:modelValue', 'change'],
    setup(props, { emit }) {
      const onClick = () => {
        if (props.disabled) return;
        const next = !props.modelValue;
        emit('update:modelValue', next);
        emit('change', next);
      };
      return { onClick };
    }
  });
</script>
