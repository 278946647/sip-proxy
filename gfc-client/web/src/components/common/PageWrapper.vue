<script setup lang="ts">
defineProps<{
  title: string
  description?: string
}>()
</script>

<template>
  <section class="wrap">
    <header class="head">
      <h2>{{ title }}</h2>
      <p v-if="description">{{ description }}</p>
    </header>
    <div class="body">
      <slot />
    </div>
  </section>
</template>

<style scoped>
.wrap {
  background: var(--panel);
  border: 1px solid var(--border);
  border-radius: 10px;
}

.head {
  padding: 12px 14px;
  border-bottom: 1px solid var(--border);
}

.head h2 {
  margin: 0;
  font-size: 16px;
}

.head p {
  margin: 4px 0 0;
  color: var(--muted);
}

.body {
  padding: 14px;
}
</style>
