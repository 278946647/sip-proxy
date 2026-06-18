<script setup lang="ts">
import { onMounted, ref } from 'vue'
import JsonBlock from '@/components/common/JsonBlock.vue'
import { policyApi } from '@/api/policy'
import { textValue } from '@/utils/data'

const loading = ref(false)
const saving = ref(false)
const message = ref('')
const error = ref('')
const payload = ref<Record<string, unknown>>({})
const mode = ref('split')

async function load() {
  loading.value = true
  error.value = ''
  try {
    const res = await policyApi.routing()
    if (res.ok) {
      payload.value = res.data
      mode.value = textValue(res.data.mode || res.data.routing_mode, 'split')
    }
  } catch (err) {
    error.value = String(err)
  } finally {
    loading.value = false
  }
}

async function save() {
  saving.value = true
  message.value = ''
  try {
    const res = await policyApi.updateRouting(mode.value)
    message.value = res.ok ? `路由模式已切换为 ${mode.value}` : (res.error?.message ?? '切换失败')
    await load()
  } catch (err) {
    message.value = String(err)
  } finally {
    saving.value = false
  }
}

onMounted(load)
</script>

<template>
  <section class="page">
    <header class="page-head">
      <div><h2>策略路由</h2><p>切换全局 / 分流等路由模式并触发本地重载。</p></div>
      <button :disabled="loading" @click="load">{{ loading ? '刷新中...' : '刷新' }}</button>
    </header>
    <div class="card">
      <label>路由模式
        <select v-model="mode">
          <option value="split">split 分流</option>
          <option value="global">global 全局代理</option>
          <option value="direct">direct 直连</option>
        </select>
      </label>
      <button :disabled="saving" @click="save">{{ saving ? '保存中...' : '保存并应用' }}</button>
      <p v-if="message" class="message">{{ message }}</p>
      <p v-if="error" class="error">{{ error }}</p>
    </div>
    <JsonBlock title="路由原始响应 /routing" :data="payload" />
  </section>
</template>

<style scoped>
.page{display:grid;gap:14px}.page-head{display:flex;justify-content:space-between;gap:12px;align-items:center}h2,p{margin:0}p{margin-top:4px;color:var(--muted)}.card{display:grid;gap:10px;background:var(--panel);border:1px solid var(--border);border-radius:10px;padding:12px;max-width:520px}label{display:grid;gap:6px;color:var(--muted)}select{border:1px solid var(--border);border-radius:8px;padding:7px;background:#fff}button{border:0;border-radius:8px;padding:8px 12px;color:#fff;background:var(--brand);cursor:pointer}.message{color:var(--ok)}.error{color:var(--danger)}
</style>
