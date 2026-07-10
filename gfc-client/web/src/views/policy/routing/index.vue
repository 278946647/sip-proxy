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
    if (!res.ok) {
      message.value = res.error?.message ?? '切换失败'
      return
    }
    if (res.data?.apply === false) {
      message.value = String(res.data?.message ?? '切换失败')
      return
    }
    if (res.data?.synced === false) {
      message.value = `本地已应用，但同步控制平面失败：${res.data?.sync_error ?? '未知错误'}`
      await load()
      return
    }
    message.value = `代理模式已切换为 ${mode.value}`
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
      <div><h2>代理模式</h2><p>切换分流 / 全局等流量代理策略并触发本地重载。</p></div>
      <button :disabled="loading" @click="load">{{ loading ? '刷新中...' : '刷新' }}</button>
    </header>
    <div class="card">
      <label>代理模式
        <select v-model="mode">
          <option value="split">split 分流模式</option>
          <option value="global">global 全局模式</option>
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
