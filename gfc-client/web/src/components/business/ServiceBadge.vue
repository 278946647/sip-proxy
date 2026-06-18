<script setup lang="ts">
import { computed } from 'vue'

const props = withDefaults(
  defineProps<{
    status: 'running' | 'stopped' | 'degraded'
  }>(),
  {
    status: 'stopped',
  },
)

const label = computed(() => {
  if (props.status === 'running') return '运行中'
  if (props.status === 'degraded') return '异常'
  return '已停止'
})
</script>

<template>
  <span class="badge" :class="`is-${status}`">{{ label }}</span>
</template>

<style scoped>
.badge {
  display: inline-flex;
  border-radius: 999px;
  padding: 2px 8px;
  border: 1px solid var(--border);
  font-size: 12px;
}

.is-running {
  color: var(--ok);
  background: #f0fdf4;
}

.is-stopped {
  color: var(--danger);
  background: #fef2f2;
}

.is-degraded {
  color: var(--warn);
  background: #fffbeb;
}
</style>
