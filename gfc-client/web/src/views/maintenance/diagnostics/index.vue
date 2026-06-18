<script setup lang="ts">
import { ref } from 'vue'
import ConfigPanel from '@/components/business/ConfigPanel.vue'
import JsonBlock from '@/components/common/JsonBlock.vue'
import { maintenanceApi } from '@/api/maintenance'
import { textValue } from '@/utils/data'

const running = ref('')
const host = ref('www.google.com')
const pingHost = ref('1.1.1.1')
const result = ref<Record<string, unknown>>({})
const message = ref('')

async function run(type: 'dns' | 'ping' | 'tun') {
  running.value = type
  message.value = ''
  try {
    const payload = type === 'dns' ? { host: host.value } : type === 'ping' ? { host: pingHost.value } : {}
    const res = await maintenanceApi.diagnostic(type, payload)
    result.value = res.data || {}
    message.value = res.ok ? `${type} 诊断完成` : (res.error?.message ?? `${type} 诊断失败`)
  } catch (err) {
    message.value = String(err)
  } finally {
    running.value = ''
  }
}
</script>

<template>
  <section class="page">
    <header class="page-head">
      <div><h2>诊断工具</h2><p>执行 DNS 解析、Ping 和 TUN 状态检查。</p></div>
    </header>
    <div v-if="message" class="notice">{{ message }}</div>
    <div class="grid">
      <ConfigPanel title="DNS 探测">
        <label>域名 <input v-model="host" /></label>
        <button :disabled="!!running" @click="run('dns')">开始 DNS 探测</button>
      </ConfigPanel>
      <ConfigPanel title="连通性测试">
        <label>目标地址 <input v-model="pingHost" /></label>
        <button :disabled="!!running" @click="run('ping')">开始 Ping</button>
      </ConfigPanel>
      <ConfigPanel title="TUN 检查">
        <p>检查 `gfctun` 接口状态。</p>
        <button :disabled="!!running" @click="run('tun')">检查 TUN</button>
      </ConfigPanel>
    </div>
    <section v-if="Object.keys(result).length" class="result">
      <h3>最近结果</h3>
      <p v-if="result.ok !== undefined">结果：{{ result.ok ? '成功' : '失败' }}</p>
      <p v-if="result.host">目标：{{ textValue(result.host) }}</p>
      <pre v-if="result.output">{{ textValue(result.output) }}</pre>
      <p v-if="result.error" class="error">{{ textValue(result.error) }}</p>
    </section>
    <JsonBlock title="诊断调试数据" :data="result" />
  </section>
</template>

<style scoped>
.page{display:grid;gap:12px}.page-head{display:flex;justify-content:space-between;align-items:center;gap:12px}h2,h3,p{margin:0}p{margin-top:4px;color:var(--muted)}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:12px}label{display:grid;gap:5px;color:#334155;font-size:13px}input{border:1px solid var(--border);border-radius:4px;padding:7px;background:#fff}button{margin-top:10px;border:0;border-radius:4px;padding:7px 12px;color:#fff;background:#2563eb;cursor:pointer}.notice{padding:8px 10px;border:1px solid #bbf7d0;background:#f0fdf4;color:#15803d;border-radius:4px}.result{display:grid;gap:8px;background:#fff;border:1px solid var(--border);border-radius:4px;padding:12px}pre{margin:0;white-space:pre-wrap;max-height:260px;overflow:auto;background:#0f172a;color:#dbeafe;padding:10px;border-radius:4px}.error{color:var(--danger)}
</style>
