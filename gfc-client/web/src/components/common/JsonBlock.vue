<script setup lang="ts">
import { jsonText } from '@/utils/data'

defineProps<{
  title?: string
  data: unknown
}>()
</script>

<template>
  <section class="json-block">
    <h3 v-if="title">{{ title }}</h3>
    <pre>{{ jsonText(data) }}</pre>
  </section>
</template>

<style scoped>
.json-block {
  border: 1px solid var(--border);
  border-radius: 10px;
  background: #0f172a;
  color: #dbeafe;
  overflow: hidden;
}

h3 {
  margin: 0;
  padding: 8px 10px;
  font-size: 13px;
  color: #e5e7eb;
  border-bottom: 1px solid #1f2937;
}

pre {
  margin: 0;
  padding: 10px;
  overflow: auto;
  max-height: 340px;
  font-size: 12px;
  line-height: 1.5;
}
</style>
