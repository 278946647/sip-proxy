<script setup lang="ts">
import { onMounted, ref } from 'vue'
import ConfigPanel from '@/components/business/ConfigPanel.vue'
import JsonBlock from '@/components/common/JsonBlock.vue'
import { maintenanceApi } from '@/api/maintenance'
import { textValue } from '@/utils/data'

const loading = ref(false)
const saving = ref(false)
const message = ref('')
const error = ref('')
const settings = ref<Record<string, unknown>>({})
const form = ref({
  domestic: '223.5.5.5',
  international: '1.1.1.1',
  doh: '',
  ecs: true,
})

async function load() {
  loading.value = true
  error.value = ''
  try {
    const res = await maintenanceApi.settings()
    if (res.ok) {
      settings.value = res.data
      form.value.domestic = textValue(res.data.dns_domestic, form.value.domestic)
      form.value.international = textValue(res.data.dns_intl || res.data.dns_international, form.value.international)
      form.value.doh = textValue(res.data.dns_doh, form.value.doh)
      form.value.ecs = Boolean(res.data.dns_ecs ?? form.value.ecs)
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
    const res = await maintenanceApi.updateSettings({
      dns_domestic: form.value.domestic,
      dns_intl: form.value.international,
      dns_doh: form.value.doh,
      dns_ecs: form.value.ecs,
    })
    message.value = res.ok ? 'DNS 上游设置已保存。' : (res.error?.message ?? '保存失败')
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
      <div><h2>DNS 上游</h2><p>配置国内/国际 DNS 上游与 DoH/ECS 参数。</p></div>
      <button :disabled="loading" @click="load">刷新</button>
    </header>
    <div v-if="message" class="notice">{{ message }}</div>
    <div v-if="error" class="error">{{ error }}</div>
    <ConfigPanel title="上游解析器">
      <div class="form-grid">
        <label>国内 DNS <input v-model="form.domestic" placeholder="223.5.5.5" /></label>
        <label>国际 DNS <input v-model="form.international" placeholder="1.1.1.1" /></label>
        <label>DoH URL <input v-model="form.doh" placeholder="https://dns.google/dns-query" /></label>
        <label class="switch"><input v-model="form.ecs" type="checkbox" /> 启用 ECS</label>
      </div>
      <div class="actions"><button :disabled="saving" @click="save">保存 DNS 设置</button></div>
    </ConfigPanel>
    <JsonBlock title="DNS 设置调试数据" :data="settings" />
  </section>
</template>

<style scoped>
.page{display:grid;gap:12px}.page-head{display:flex;justify-content:space-between;align-items:center;gap:12px}h2,p{margin:0}p{margin-top:4px;color:var(--muted)}button{border:0;border-radius:4px;padding:7px 12px;color:#fff;background:#2563eb;cursor:pointer}.form-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:12px}label{display:grid;gap:5px;color:#334155;font-size:13px}.switch{display:flex;gap:8px;align-items:center}input{border:1px solid var(--border);border-radius:4px;padding:7px;background:#fff}.actions{margin-top:12px}.notice{padding:8px 10px;border:1px solid #bbf7d0;background:#f0fdf4;color:#15803d;border-radius:4px}.error{color:var(--danger)}
</style>
