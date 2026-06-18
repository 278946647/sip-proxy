<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import ConfigPanel from '@/components/business/ConfigPanel.vue'
import DataTable from '@/components/common/DataTable.vue'
import JsonBlock from '@/components/common/JsonBlock.vue'
import { networkApi } from '@/api/network'
import { asArray, asRecord } from '@/utils/data'

const loading = ref(false)
const saving = ref(false)
const message = ref('')
const error = ref('')
const payload = ref<Record<string, unknown>>({})
const form = ref({ destination: '', gateway: '', interface: '', metric: 100 })

const rows = computed(() => asArray(payload.value.routes).map(asRecord))

async function load() {
  loading.value = true
  error.value = ''
  try {
    const res = await networkApi.routes()
    if (res.ok) payload.value = res.data
  } catch (err) {
    error.value = String(err)
  } finally {
    loading.value = false
  }
}

async function save(routes: Array<Record<string, unknown>>) {
  saving.value = true
  message.value = ''
  try {
    const res = await networkApi.updateRoutes({ routes })
    message.value = res.ok ? '静态路由配置已保存。' : (res.error?.message ?? '保存失败')
    await load()
  } catch (err) {
    message.value = String(err)
  } finally {
    saving.value = false
  }
}

function addRoute() {
  if (!form.value.destination || !form.value.gateway) {
    message.value = '请输入目标网段和下一跳'
    return
  }
  save([...rows.value, { ...form.value }])
  form.value = { destination: '', gateway: '', interface: '', metric: 100 }
}

function removeRoute(index: number) {
  save(rows.value.filter((_, i) => i !== index))
}

onMounted(load)
</script>

<template>
  <section class="page">
    <header class="page-head">
      <div><h2>静态路由</h2><p>维护设备侧静态路由配置。</p></div>
      <button :disabled="loading" @click="load">刷新</button>
    </header>
    <div v-if="message" class="notice">{{ message }}</div>
    <div v-if="error" class="error">{{ error }}</div>
    <ConfigPanel title="新增静态路由">
      <div class="form-grid">
        <label>目标网段 <input v-model="form.destination" placeholder="10.10.0.0/16" /></label>
        <label>下一跳 <input v-model="form.gateway" placeholder="192.168.68.254" /></label>
        <label>出接口 <input v-model="form.interface" placeholder="可选" /></label>
        <label>Metric <input v-model.number="form.metric" type="number" /></label>
      </div>
      <div class="actions"><button :disabled="saving" @click="addRoute">添加并保存</button></div>
    </ConfigPanel>
    <DataTable :columns="[
      { key: 'destination', title: '目标网段' },
      { key: 'gateway', title: '下一跳' },
      { key: 'interface', title: '出接口' },
      { key: 'metric', title: 'Metric' },
    ]" :rows="rows">
      <template #actions="{ index }">
        <button class="danger" :disabled="saving" @click="removeRoute(index)">删除</button>
      </template>
    </DataTable>
    <JsonBlock title="静态路由调试数据" :data="payload" />
  </section>
</template>

<style scoped>
.page{display:grid;gap:12px}.page-head{display:flex;justify-content:space-between;align-items:center;gap:12px}h2,p{margin:0}p{margin-top:4px;color:var(--muted)}button{border:0;border-radius:4px;padding:7px 12px;color:#fff;background:#2563eb;cursor:pointer}.danger{background:var(--danger)}.form-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:12px}label{display:grid;gap:5px;color:#334155;font-size:13px}input{border:1px solid var(--border);border-radius:4px;padding:7px;background:#fff}.actions{margin-top:12px}.notice{padding:8px 10px;border:1px solid #bbf7d0;background:#f0fdf4;color:#15803d;border-radius:4px}.error{color:var(--danger)}
</style>
