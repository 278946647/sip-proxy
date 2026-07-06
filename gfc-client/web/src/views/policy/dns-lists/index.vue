<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import JsonBlock from '@/components/common/JsonBlock.vue'
import { policyApi } from '@/api/policy'
import { asRecord, textValue } from '@/utils/data'

const loading = ref(false)
const saving = ref(false)
const error = ref('')
const message = ref('')
const payload = ref<Record<string, unknown>>({})
const listName = ref('china')
const action = ref<'append' | 'delete'>('append')
const domains = ref('')
const importReplace = ref(false)
const exportContent = ref('')

const lists = computed(() => asRecord(payload.value.lists || payload.value))
const listNames = computed(() => Object.keys(lists.value))

async function load() {
  loading.value = true
  error.value = ''
  try {
    const res = await policyApi.dnsLists()
    if (res.ok) {
      payload.value = res.data
      if (!listNames.value.includes(listName.value) && listNames.value[0]) listName.value = listNames.value[0]
    }
  } catch (err) {
    error.value = String(err)
  } finally {
    loading.value = false
  }
}

function domainLines() {
  return domains.value.split('\n').map((item) => item.trim()).filter(Boolean)
}

async function updateList() {
  const lines = domainLines()
  if (!lines.length) {
    message.value = '请输入至少一个域名'
    return
  }
  saving.value = true
  message.value = ''
  try {
    const res = await policyApi.updateDnsList(listName.value, { action: action.value, domains: lines })
    message.value = res.ok ? `${action.value === 'append' ? '追加' : '删除'} ${lines.length} 条完成` : (res.error?.message ?? '操作失败')
    domains.value = ''
    await load()
  } catch (err) {
    message.value = String(err)
  } finally {
    saving.value = false
  }
}

async function importList() {
  saving.value = true
  message.value = ''
  try {
    const res = await policyApi.importDnsList(listName.value, { content: domains.value, replace: importReplace.value })
    message.value = res.ok ? '导入完成' : (res.error?.message ?? '导入失败')
    await load()
  } catch (err) {
    message.value = String(err)
  } finally {
    saving.value = false
  }
}

async function exportList() {
  saving.value = true
  try {
    const res = await policyApi.exportDnsList(listName.value)
    exportContent.value = res.ok ? textValue(res.data.content) : (res.error?.message ?? '')
  } finally {
    saving.value = false
  }
}

async function updateEasy() {
  saving.value = true
  try {
    const res = await policyApi.easyMosdnsUpdate()
    message.value = res.ok ? 'Unbound 域名列表已更新并重载' : (res.error?.message ?? '更新失败')
    await load()
  } finally {
    saving.value = false
  }
}

onMounted(load)
</script>

<template>
  <section class="page">
    <header class="page-head">
      <div><h2>DNS 分流 / 域名列表</h2><p>管理本地域名列表并触发 Unbound 规则更新。</p></div>
      <button :disabled="loading" @click="load">{{ loading ? '刷新中...' : '刷新' }}</button>
    </header>
    <div class="cards">
      <div v-for="name in listNames" :key="name" class="stat">
        <span>{{ name }}</span>
        <strong>{{ textValue(asRecord(lists[name]).count || asRecord(lists[name]).lines) }}</strong>
      </div>
    </div>
    <div class="card">
      <div class="toolbar">
        <label>列表<select v-model="listName"><option v-for="name in listNames" :key="name" :value="name">{{ name }}</option></select></label>
        <label>动作<select v-model="action"><option value="append">追加</option><option value="delete">删除</option></select></label>
      </div>
      <textarea v-model="domains" rows="8" placeholder="每行一个域名，例如 example.com" />
      <label class="check"><input v-model="importReplace" type="checkbox" /> 导入时替换整个列表</label>
      <div class="actions">
        <button :disabled="saving" @click="updateList">按行追加/删除</button>
        <button :disabled="saving" @click="importList">导入内容</button>
        <button :disabled="saving" @click="exportList">导出列表</button>
        <button :disabled="saving" @click="updateEasy">更新 Unbound 列表</button>
      </div>
      <p v-if="message" class="message">{{ message }}</p>
      <p v-if="error" class="error">{{ error }}</p>
    </div>
    <div v-if="exportContent" class="card"><h3>导出内容</h3><pre>{{ exportContent }}</pre></div>
    <JsonBlock title="DNS 列表原始响应" :data="payload" />
  </section>
</template>

<style scoped>
.page{display:grid;gap:14px}.page-head{display:flex;justify-content:space-between;gap:12px;align-items:center}h2,h3,p{margin:0}p{margin-top:4px;color:var(--muted)}button{border:0;border-radius:8px;padding:8px 12px;color:#fff;background:var(--brand);cursor:pointer}.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:10px}.stat,.card{background:var(--panel);border:1px solid var(--border);border-radius:10px;padding:12px}.stat{display:grid;gap:6px}.stat span{color:var(--muted);font-size:12px}.stat strong{font-size:20px}.toolbar,.actions{display:flex;flex-wrap:wrap;gap:10px}.card{display:grid;gap:10px}label{display:flex;gap:6px;align-items:center;color:var(--muted)}select,textarea{border:1px solid var(--border);border-radius:8px;padding:7px;background:#fff}textarea{width:100%;resize:vertical}.check{justify-content:flex-start}.message{color:var(--ok)}.error{color:var(--danger)}pre{margin:0;white-space:pre-wrap;max-height:320px;overflow:auto}
</style>
