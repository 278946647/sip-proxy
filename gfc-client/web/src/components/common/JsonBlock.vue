<script setup lang="ts">
import { jsonText } from '@/utils/data'

withDefaults(defineProps<{
  title?: string
  data: unknown
  open?: boolean
}>(), {
  title: '调试数据',
  open: false,
})
</script>

<template>
  <details class="json-block" :open="open">
    <summary>{{ title }}</summary>
    <pre>{{ jsonText(data) }}</pre>
  </details>
</template>

<style scoped>
.json-block {
  border: 1px solid var(--border);
  border-radius: 4px;
  background: #fff;
  color: var(--text);
  overflow: hidden;
}

summary {
  cursor: pointer;
  padding: 9px 10px;
  font-size: 13px;
  font-weight: 600;
  color: #334155;
  background: #f8fafc;
  border-bottom: 1px solid var(--border);
}

pre {
  margin: 0;
  padding: 10px;
  overflow: auto;
  max-height: 340px;
  font-size: 12px;
  line-height: 1.5;
  color: #dbeafe;
  background: #0f172a;
}
</style>
