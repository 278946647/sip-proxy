<script setup lang="ts">
import { computed } from 'vue'
import { useRoute } from 'vue-router'

const route = useRoute()
const title = computed(() => String(route.meta.title ?? '未命名页面'))
</script>

<template>
  <section class="page">
    <h2>{{ title }}</h2>
    <p>企业级后台骨架已创建。该页面已接入动态路由与权限过滤，可按模块继续填充业务组件。</p>
    <div class="meta">
      <code>path: {{ route.path }}</code>
    </div>
  </section>
</template>

<style scoped>
.page {
  background: var(--panel);
  border: 1px solid var(--border);
  border-radius: 10px;
  padding: 16px;
}

h2 {
  margin: 0 0 8px;
  font-size: 18px;
}

p {
  margin: 0;
  color: var(--muted);
}

.meta {
  margin-top: 12px;
}

code {
  background: #f3f4f6;
  border: 1px solid #e5e7eb;
  border-radius: 6px;
  padding: 4px 8px;
}
</style>
