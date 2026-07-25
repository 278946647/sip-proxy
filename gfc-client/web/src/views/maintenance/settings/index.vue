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
  live_mode: 'standard',
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
      form.value.live_mode = textValue(res.data.live_mode, 'standard')
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
    const routingApply = res.data?.routing_apply as { ok?: boolean; message?: string } | undefined
    if (routingApply && routingApply.ok === false) {
      message.value = routingApply.message ?? '代理模式应用失败'
    } else if (res.data?.synced === false) {
      message.value = `本地已保存，但同步控制平面失败：${res.data?.sync_error ?? '未知错误'}`
    } else if (res.data?.dataplane && (res.data.dataplane as { ok?: boolean }).ok === false) {
      message.value = (res.data.dataplane as { message?: string }).message ?? '设置已保存，但数据面应用失败'
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
      <label>直播模式
        <select v-model="form.live_mode">
          <option value="standard">standard 标准（国际走 VLESS）</option>
          <option value="live_all_hy2">live_all_hy2 全国际 Hysteria2</option>
          <option value="live_catalog" disabled>live_catalog 目录分流（P1 未启用）</option>
        </select>
      </label>
      <label>国内 DNS<input v-model="form.dns_domestic" placeholder="例如 223.5.5.5" /></label>
      <label>国际 DNS<input v-model="form.dns_intl" placeholder="例如 1.1.1.1" /></label>
      <button :disabled="saving" @click="save">{{ saving ? '保存中...' : '保存设置' }}</button>
      <p class="hint">直播模式与控制平台线路配置双向同步；切换后会立即拉取并应用配置。</p>
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
.page{display:grid;gap:14px}.page-head{display:flex;justify-content:space-between;gap:12px;align-items:center}h2,p{margin:0}p{margin-top:4px;color:var(--muted)}.card{display:grid;gap:10px;background:var(--panel);border:1px solid var(--border);border-radius:10px;padding:12px;max-width:680px}label{display:grid;gap:6px;color:var(--muted)}input,select{border:1px solid var(--border);border-radius:8px;padding:7px;background:#fff}.actions{display:flex;flex-wrap:wrap;gap:8px}button{border:0;border-radius:8px;padding:8px 12px;color:#fff;background:var(--brand);cursor:pointer}.message{color:var(--ok)}.error{color:var(--danger)}.hint{color:var(--muted);font-size:12px}
</style>
