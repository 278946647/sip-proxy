<script setup lang="ts">
import { computed } from 'vue'
import { useRouter } from 'vue-router'
import { removeToken } from '@/utils/auth'

const props = defineProps<{ title: string }>()
const router = useRouter()

const flashHref = computed(() => `http://${window.location.hostname}/flash.html`)

function logout() {
  removeToken()
  router.push('/login')
}
</script>

<template>
  <header class="header">
    <div class="title">{{ props.title }}</div>
    <div class="actions">
      <a :href="flashHref" target="_blank" rel="noreferrer">刷码页</a>
      <button @click="logout">退出</button>
    </div>
  </header>
</template>

<style scoped>
.header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 12px 16px;
  background: var(--panel);
  border-bottom: 1px solid var(--border);
}

.title {
  font-size: 16px;
  font-weight: 600;
}

.actions {
  display: flex;
  gap: 12px;
  align-items: center;
  color: var(--muted);
}

button {
  border: 1px solid var(--border);
  background: #fff;
  border-radius: 6px;
  padding: 4px 10px;
  cursor: pointer;
}
</style>
