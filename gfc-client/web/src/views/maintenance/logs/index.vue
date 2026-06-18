<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import JsonBlock from '@/components/common/JsonBlock.vue'
import { maintenanceApi } from '@/api/maintenance'
import { asArray, textValue } from '@/utils/data'

const services = ['agent', 'api', 'mosdns', 'singbox', 'system']
const service = ref('agent')
const lines = ref(200)
const loading = ref(false)
const error = ref('')
const payload = ref<Record<string, unknown>>({})

const logLines = computed(() => {
  const data = payload.value
  const direct = asArray(data.lines)
  if (direct.length) return direct.map((line) => textValue(line, ''))
  const logs = asArray(data.logs)
  if (logs.length) return logs.map((line) => textValue(line, ''))
  const text = textValue(data.content || data.text || data.log, '')
  return text ? text.split('\n') : []
})

async function load() {
  loading.value = true
  error.value = ''
  try {
    const res = await maintenanceApi.logs(service.value, lines.value)
    if (res.ok) payload.value = res.data
  } catch (err) {
    error.value = String(err)
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
        <p>按服务读取后端日志尾部，默认保留轻量文本展示。</p>
      </div>
      <button :disabled="loading" @click="load">{{ loading ? '读取中...' : '刷新' }}</button>
    </header>

    <div class="toolbar">
      <label>
        服务
        <select v-model="service" @change="load">
          <option v-for="item in services" :key="item" :value="item">{{ item }}</option>
        </select>
      </label>
      <label>
        行数
        <select v-model.number="lines" @change="load">
          <option :value="100">100</option>
          <option :value="200">200</option>
          <option :value="500">500</option>
        </select>
      </label>
    </div>

    <div v-if="error" class="error">{{ error }}</div>
    <pre class="log-view" v-if="logLines.length">{{ logLines.join('\n') }}</pre>
    <JsonBlock v-else title="日志原始响应 /logs" :data="payload" />
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

.toolbar {
  display: flex;
  gap: 12px;
  flex-wrap: wrap;
}

label {
  display: flex;
  gap: 6px;
  align-items: center;
  color: var(--muted);
}

select {
  border: 1px solid var(--border);
  border-radius: 8px;
  padding: 6px 8px;
  background: #fff;
}

button {
  border: 0;
  border-radius: 8px;
  padding: 8px 12px;
  color: #fff;
  background: var(--brand);
  cursor: pointer;
}

.log-view {
  margin: 0;
  padding: 12px;
  max-height: calc(100vh - 230px);
  overflow: auto;
  border-radius: 10px;
  background: #020617;
  color: #d1fae5;
  font-size: 12px;
  line-height: 1.5;
}

.error {
  color: var(--danger);
}
</style>
