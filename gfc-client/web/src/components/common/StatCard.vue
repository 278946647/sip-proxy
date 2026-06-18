<script setup lang="ts">
defineProps<{
  label: string
  value: string
  tone?: 'ok' | 'warn' | 'danger' | 'normal'
}>()
</script>

<template>
  <div class="stat-card" :class="tone ? `is-${tone}` : 'is-normal'">
    <span>{{ label }}</span>
    <strong>{{ value }}</strong>
  </div>
</template>

<style scoped>
.stat-card {
  background: var(--panel);
  border: 1px solid var(--border);
  border-radius: 10px;
  padding: 12px;
  display: grid;
  gap: 6px;
}

span {
  color: var(--muted);
  font-size: 12px;
}

strong {
  font-size: 20px;
}

.is-ok strong {
  color: var(--ok);
}

.is-warn strong {
  color: var(--warn);
}

.is-danger strong {
  color: var(--danger);
}
</style>
