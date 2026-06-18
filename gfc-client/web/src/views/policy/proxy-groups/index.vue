<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import JsonBlock from '@/components/common/JsonBlock.vue'
import { policyApi } from '@/api/policy'
import { asArray, asRecord, textValue } from '@/utils/data'

const loading = ref(false)
const saving = ref('')
const message = ref('')
const error = ref('')
const payload = ref<Record<string, unknown>>({})
const manualOutbound = ref<Record<string, string>>({})

const groups = computed(() => asArray(payload.value.groups).map(asRecord))

async function load() {
  loading.value = true
  error.value = ''
  try {
    const res = await policyApi.groups()
    if (res.ok) payload.value = res.data
  } catch (err) {
    error.value = String(err)
  } finally {
    loading.value = false
  }
}

function groupId(row: Record<string, unknown>) {
  return textValue(row.id || row.name || row.tag, '')
}

function outbounds(row: Record<string, unknown>) {
  return asArray(row.outbounds || row.options || row.nodes).map((item) => {
    const record = asRecord(item)
    return textValue(record.tag || record.id || record.name || item, '')
  }).filter(Boolean)
}

async function select(row: Record<string, unknown>, outbound: string) {
  const id = groupId(row)
  if (!id || !outbound) return
  saving.value = id
  try {
    const res = await policyApi.selectGroup(id, outbound)
    message.value = res.ok ? `${id} 已切换到 ${outbound}` : (res.error?.message ?? '切换失败')
    await load()
  } catch (err) {
    message.value = String(err)
  } finally {
    saving.value = ''
  }
}

onMounted(load)
</script>

<template>
  <section class="page">
    <header class="page-head">
      <div><h2>代理策略组</h2><p>展示并切换当前策略组出站。</p></div>
      <button :disabled="loading" @click="load">{{ loading ? '刷新中...' : '刷新' }}</button>
    </header>
    <div v-if="message" class="message">{{ message }}</div>
    <div v-if="error" class="error">{{ error }}</div>
    <div class="grid">
      <div v-for="(group, index) in groups" :key="`${groupId(group)}-${index}`" class="card">
        <h3>{{ textValue(group.name || groupId(group) || `策略组 ${index + 1}`) }}</h3>
        <p>当前：{{ textValue(group.selected || group.current || group.outbound) }}</p>
        <div class="actions">
          <button v-for="item in outbounds(group)" :key="item" :disabled="saving === groupId(group)" @click="select(group, item)">
            {{ item }}
          </button>
        </div>
        <div v-if="!outbounds(group).length" class="manual">
          <input v-model="manualOutbound[groupId(group)]" placeholder="输入 outbound/tag" />
          <button :disabled="saving === groupId(group)" @click="select(group, manualOutbound[groupId(group)])">切换</button>
        </div>
      </div>
    </div>
    <JsonBlock title="策略组原始响应" :data="payload" />
  </section>
</template>

<style scoped>
.page{display:grid;gap:14px}.page-head{display:flex;justify-content:space-between;gap:12px;align-items:center}h2,h3,p{margin:0}p{margin-top:4px;color:var(--muted)}button{border:0;border-radius:8px;padding:8px 12px;color:#fff;background:var(--brand);cursor:pointer}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:12px}.card{display:grid;gap:10px;background:var(--panel);border:1px solid var(--border);border-radius:10px;padding:12px}.actions,.manual{display:flex;flex-wrap:wrap;gap:8px}.manual input{flex:1;min-width:140px;border:1px solid var(--border);border-radius:8px;padding:7px}.message{color:var(--ok)}.error{color:var(--danger)}
</style>
