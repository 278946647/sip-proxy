<script setup lang="ts">
import { onMounted, ref } from 'vue'
import JsonBlock from '@/components/common/JsonBlock.vue'
import { maintenanceApi } from '@/api/maintenance'
import { textValue } from '@/utils/data'

const loading = ref(false)
const saving = ref(false)
const message = ref('')
const error = ref('')
const settings = ref<Record<string, unknown>>({})
const form = ref({
  proxy_mode: 'gateway',
  routing_mode: 'split',
  dns_domestic: '',
  dns_intl: '',
})

async function load() {
  loading.value = true
  error.value = ''
  try {
    const res = await maintenanceApi.settings()
    if (res.ok) {
      settings.value = res.data
      form.value.proxy_mode = textValue(res.data.proxy_mode, 'gateway')
      form.value.routing_mode = textValue(res.data.routing_mode, 'split')
      form.value.dns_domestic = textValue(res.data.dns_domestic, '')
      form.value.dns_intl = textValue(res.data.dns_intl, '')
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
    const res = await maintenanceApi.updateSettings({ ...form.value })
    if (!res.ok) {
      message.value = res.error?.message ?? '保存失败'
      return
    }
    const dataplane = res.data?.dataplane as { ok?: boolean; message?: string } | undefined
    if (dataplane && dataplane.ok === false) {
      message.value = dataplane.message ?? '设置已保存，但数据面应用失败'
    } else if (res.data?.synced === false) {
      message.value = `本地已保存，但同步控制平面失败：${res.data?.sync_error ?? '未知错误'}`
    } else if (res.data?.proxy_synced === false) {
      message.value = `本地已保存，但路由模式同步控制平面失败：${res.data?.proxy_sync_error ?? '未知错误'}`
    } else {
      message.value = '设置已保存'
    }
    await load()
  } catch (err) {
    message.value = String(err)
  } finally {
    saving.value = false
  }
}

async function setLogLevel(level: string) {
  saving.value = true
  try {
    const res = await maintenanceApi.updateSingboxLogging(level)
    message.value = res.ok ? `sing-box 日志级别已切换为 ${level}` : (res.error?.message ?? '切换失败')
  } finally {
    saving.value = false
  }
}

onMounted(load)
</script>

<template>
  <section class="page">
    <header class="page-head">
      <div><h2>系统设置</h2><p>管理路由模式、DNS 与 sing-box 日志级别。</p></div>
      <button :disabled="loading" @click="load">刷新</button>
    </header>
    <div class="card">
      <label>路由模式
        <select v-model="form.proxy_mode">
          <option value="gateway">gateway 网关模式</option>
          <option value="bypass">bypass 旁路模式</option>
          <option value="transparent">transparent 透明模式</option>
        </select>
      </label>
      <label>代理模式
        <select v-model="form.routing_mode">
          <option value="split">split 分流模式</option>
          <option value="global">global 全局模式</option>
        </select>
      </label>
      <label>国内 DNS<input v-model="form.dns_domestic" placeholder="例如 223.5.5.5" /></label>
      <label>国际 DNS<input v-model="form.dns_intl" placeholder="例如 1.1.1.1" /></label>
      <button :disabled="saving" @click="save">{{ saving ? '保存中...' : '保存设置' }}</button>
      <div class="actions">
        <button :disabled="saving" @click="setLogLevel('error')">日志 error</button>
        <button :disabled="saving" @click="setLogLevel('info')">日志 info</button>
        <button :disabled="saving" @click="setLogLevel('debug')">日志 debug</button>
      </div>
      <p v-if="message" class="message">{{ message }}</p>
      <p v-if="error" class="error">{{ error }}</p>
    </div>
    <JsonBlock title="设置原始响应 /settings" :data="settings" />
  </section>
</template>

<style scoped>
.page{display:grid;gap:14px}.page-head{display:flex;justify-content:space-between;gap:12px;align-items:center}h2,p{margin:0}p{margin-top:4px;color:var(--muted)}.card{display:grid;gap:10px;background:var(--panel);border:1px solid var(--border);border-radius:10px;padding:12px;max-width:680px}label{display:grid;gap:6px;color:var(--muted)}input,select{border:1px solid var(--border);border-radius:8px;padding:7px;background:#fff}.actions{display:flex;flex-wrap:wrap;gap:8px}button{border:0;border-radius:8px;padding:8px 12px;color:#fff;background:var(--brand);cursor:pointer}.message{color:var(--ok)}.error{color:var(--danger)}
</style>
