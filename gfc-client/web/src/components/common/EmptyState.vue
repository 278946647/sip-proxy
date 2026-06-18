<script setup lang="ts">
defineProps<{ text?: string }>()
</script>

<template>
  <div class="empty">{{ text || '暂无数据' }}</div>
</template>

<style scoped>
.empty {
  border: 1px dashed var(--border);
  border-radius: 8px;
  padding: 16px;
  color: var(--muted);
  text-align: center;
}
</style>
