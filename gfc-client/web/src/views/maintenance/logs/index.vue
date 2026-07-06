<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { maintenanceApi } from '@/api/maintenance'

const loading = ref(false)
const error = ref('')
const service = ref('agent')
const lines = ref<string[]>([])

const services = [
  { value: 'agent', label: 'gfc-agent' },
  { value: 'api', label: 'gfc-api' },
  { value: 'unbound', label: 'unbound' },
  { value: 'sing-box', label: 'sing-box' },
]

async function load() {
  loading.value = true
  error.value = ''
  try {
    const res = await maintenanceApi.logs(service.value, 200)
    if (res.ok) {
      const data = res.data as { lines?: string[] }
      lines.value = Array.isArray(data.lines) ? data.lines : []
    } else {
      error.value = res.error?.message ?? '读取日志失败'
      lines.value = []
    }
  } catch (err) {
    error.value = String(err)
    lines.value = []
  } finally {
    loading.value = false
  }
}

onMounted(load)
</script>

<template>
  <section class="page">
    <header class="page-head">
      <div>
        <h2>日志中心</h2>
        <p>查看核心服务最近日志（agent / api / unbound / sing-box）。</p>
      </div>
      <button :disabled="loading" @click="load">{{ loading ? '刷新中...' : '刷新' }}</button>
    </header>

    <div class="toolbar">
      <label>
        服务
        <select v-model="service" @change="load">
          <option v-for="item in services" :key="item.value" :value="item.value">{{ item.label }}</option>
        </select>
      </label>
    </div>

    <p v-if="error" class="error">{{ error }}</p>

    <pre class="log-box">{{ lines.length ? lines.join('\n') : (loading ? '加载中...' : '暂无日志') }}</pre>
  </section>
</template>

<style scoped>
.page {
  display: grid;
  gap: 14px;
}

.page-head {
  display: flex;
  justify-content: space-between;
  gap: 12px;
  align-items: center;
}

h2,
p {
  margin: 0;
}

p {
  margin-top: 4px;
  color: var(--muted);
}

button {
  border: 0;
  border-radius: 8px;
  padding: 8px 12px;
  color: #fff;
  background: var(--brand);
  cursor: pointer;
}

.toolbar label {
  display: flex;
  gap: 8px;
  align-items: center;
  color: var(--muted);
}

select {
  border: 1px solid var(--border);
  border-radius: 8px;
  padding: 6px 8px;
  background: #fff;
}

.log-box {
  margin: 0;
  min-height: 360px;
  max-height: 70vh;
  overflow: auto;
  white-space: pre-wrap;
  word-break: break-word;
  background: #0f172a;
  color: #e2e8f0;
  border-radius: 10px;
  padding: 12px;
  font-size: 12px;
  line-height: 1.45;
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
}

.error {
  color: var(--danger);
}
</style>
