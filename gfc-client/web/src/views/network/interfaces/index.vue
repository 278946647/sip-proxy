<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import JsonBlock from '@/components/common/JsonBlock.vue'
import { networkApi } from '@/api/network'
import { asArray, asRecord, textValue } from '@/utils/data'

const loading = ref(false)
const error = ref('')
const payload = ref<Record<string, unknown>>({})

const rows = computed(() => {
  const interfaces = payload.value.interfaces
  if (Array.isArray(interfaces)) return interfaces.map(asRecord)
  return Object.entries(asRecord(interfaces)).map(([name, value]) => ({ name, ...asRecord(value) }))
})

async function load() {
  loading.value = true
  error.value = ''
  try {
    const res = await networkApi.interfaces()
    if (res.ok) payload.value = res.data
  } catch (err) {
    error.value = String(err)
  } finally {
    loading.value = false
  }
}

function addresses(row: Record<string, unknown>) {
  return asArray(row.addresses || row.addrs || row.ip).map((item) => textValue(item)).join(', ') || textValue(row.address || row.ipv4)
}

onMounted(load)
</script>

<template>
  <section class="page">
    <header class="page-head">
      <div>
        <h2>接口管理</h2>
        <p>只读展示系统网卡、地址、状态与链路信息。</p>
      </div>
      <button :disabled="loading" @click="load">{{ loading ? '刷新中...' : '刷新' }}</button>
    </header>
    <div v-if="error" class="error">{{ error }}</div>
    <div class="card">
      <table v-if="rows.length">
        <thead><tr><th>接口</th><th>状态</th><th>MAC</th><th>地址</th></tr></thead>
        <tbody>
          <tr v-for="(row, index) in rows" :key="`${textValue(row.name || row.ifname)}-${index}`">
            <td>{{ textValue(row.name || row.ifname || row.interface) }}</td>
            <td>{{ textValue(row.state || row.status || row.operstate) }}</td>
            <td>{{ textValue(row.mac || row.hwaddr || row.hardware_addr) }}</td>
            <td>{{ addresses(row) }}</td>
          </tr>
        </tbody>
      </table>
      <p v-else>暂无接口列表。</p>
    </div>
    <JsonBlock title="接口原始响应 /network/interfaces" :data="payload" />
  </section>
</template>

<style scoped>
.page{display:grid;gap:14px}.page-head{display:flex;justify-content:space-between;gap:12px;align-items:center}h2,p{margin:0}p{margin-top:4px;color:var(--muted)}button{border:0;border-radius:8px;padding:8px 12px;color:#fff;background:var(--brand);cursor:pointer}.card{background:var(--panel);border:1px solid var(--border);border-radius:10px;overflow:auto}table{width:100%;border-collapse:collapse}th,td{text-align:left;border-bottom:1px solid var(--border);padding:9px 10px}th{background:#f8fafc}.error{color:var(--danger)}
</style>
