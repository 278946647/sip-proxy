<script setup lang="ts">
import { onMounted, ref } from 'vue'
import JsonBlock from '@/components/common/JsonBlock.vue'
import { policyApi } from '@/api/policy'

const loading = ref(false)
const saving = ref(false)
const message = ref('')
const error = ref('')
const rules = ref<Record<string, unknown>>({})

async function load() {
  loading.value = true
  error.value = ''
  try {
    const res = await policyApi.rules()
    if (res.ok) rules.value = res.data
  } catch (err) {
    error.value = String(err)
  } finally {
    loading.value = false
  }
}

async function update() {
  saving.value = true
  message.value = ''
  try {
    const res = await policyApi.updateRules()
    message.value = res.ok ? '规则集已更新并重新应用' : (res.error?.message ?? '更新失败')
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
      <div><h2>规则集管理</h2><p>查看 GeoSite / GeoIP 规则文件可用性并手动更新。</p></div>
      <div class="actions">
        <button :disabled="loading" @click="load">刷新</button>
        <button :disabled="saving" @click="update">{{ saving ? '更新中...' : '更新规则集' }}</button>
      </div>
    </header>
    <p v-if="message" class="message">{{ message }}</p>
    <p v-if="error" class="error">{{ error }}</p>
    <JsonBlock title="规则集原始响应 /rules" :data="rules" />
  </section>
</template>

<style scoped>
.page{display:grid;gap:14px}.page-head{display:flex;justify-content:space-between;gap:12px;align-items:center}h2,p{margin:0}p{margin-top:4px;color:var(--muted)}.actions{display:flex;gap:8px}button{border:0;border-radius:8px;padding:8px 12px;color:#fff;background:var(--brand);cursor:pointer}.message{color:var(--ok)}.error{color:var(--danger)}
</style>
