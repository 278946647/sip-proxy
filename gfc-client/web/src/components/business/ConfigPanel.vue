<script setup lang="ts">
defineProps<{
  title: string
  description?: string
}>()
</script>

<template>
  <section class="panel">
    <header>
      <div>
        <h3>{{ title }}</h3>
        <p v-if="description">{{ description }}</p>
      </div>
      <slot name="actions" />
    </header>
    <div class="body">
      <slot />
    </div>
  </section>
</template>

<style scoped>
.panel {
  background: var(--panel);
  border: 1px solid var(--border);
  border-radius: 4px;
  box-shadow: 0 1px 2px rgba(15, 23, 42, .06);
}

header {
  min-height: 42px;
  padding: 10px 12px;
  display: flex;
  justify-content: space-between;
  align-items: center;
  border-bottom: 1px solid var(--border);
  background: #f8fafc;
}

h3,
p {
  margin: 0;
}

h3 {
  font-size: 14px;
}

p {
  margin-top: 3px;
  color: var(--muted);
  font-size: 12px;
}

.body {
  padding: 12px;
}
</style>
