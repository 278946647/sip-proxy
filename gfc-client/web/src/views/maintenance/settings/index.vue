<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref } from 'vue'
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
  isp_port: '',
  cpe_port: '',
  dns_hijack: true,
  dns_hijack_exclude: '',
  wan_address: '',
  wan_netmask: '',
  wan_gateway: '',
  customer_hosts: '',
})
const pending = ref<Record<string, unknown> | null>(null)
let poll: ReturnType<typeof setInterval> | null = null

const interfaces = computed(() => {
  const raw = settings.value.interfaces
  const skip = new Set(['br-lan', 'gfctun', 'gfc-ce', 'gfc-dns', 'br-trans', 'lo'])
  const slaves = settings.value.lan_bridge_ports
  if (Array.isArray(slaves)) {
    for (const n of slaves) skip.add(String(n))
  }
  return Array.isArray(raw) ? raw.map(String).filter((n) => !skip.has(n)) : []
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
      form.value.isp_port = textValue(res.data.isp_port, '')
      form.value.cpe_port = textValue(res.data.cpe_port, '')
      form.value.dns_hijack = res.data.dns_hijack !== false
      const ex = res.data.dns_hijack_exclude
      form.value.dns_hijack_exclude = Array.isArray(ex) ? ex.join('\n') : textValue(ex, '')
      form.value.customer_hosts = Array.isArray(res.data.customer_hosts) ? (res.data.customer_hosts as string[]).join('\n') : ''
      pending.value = (res.data.proxy_mode_pending as Record<string, unknown>) || null
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
    const body: Record<string, unknown> = {
      proxy_mode: form.value.proxy_mode,
      confirm_timeout_sec: 120,
      dns_hijack: form.value.dns_hijack,
      dns_hijack_exclude_text: form.value.dns_hijack_exclude,
      routing_mode: form.value.routing_mode,
      live_mode: form.value.live_mode,
      dns_domestic: form.value.dns_domestic,
      dns_intl: form.value.dns_intl,
    }
    if (form.value.proxy_mode === 'bypass') {
      body.wan = {
        mode: 'static',
        address: form.value.wan_address,
        netmask: form.value.wan_netmask,
        gateway: form.value.wan_gateway,
      }
      body.customer_hosts_text = form.value.customer_hosts
    }
    if (form.value.proxy_mode === 'transparent') {
      body.isp_port = form.value.isp_port
      body.cpe_port = form.value.cpe_port
    }
    const res = await maintenanceApi.updateSettings(body)
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
      message.value = '设置已提交（模式切换请在超时前确认）'
    }
    await load()
  } catch (err) {
    message.value = String(err)
  } finally {
    saving.value = false
  }
}

async function confirmMode() {
  message.value = ''
  try {
    const token = String(pending.value?.token || '')
    const res = await maintenanceApi.confirmProxyMode(token)
    message.value = res.ok ? '已确认' : (res.error?.message ?? '确认失败')
    await load()
  } catch (err) {
    message.value = String(err)
  }
}

async function rollbackMode() {
  message.value = ''
  try {
    const res = await maintenanceApi.rollbackProxyMode()
    message.value = res.ok ? '已回滚' : (res.error?.message ?? '回滚失败')
    await load()
  } catch (err) {
    message.value = String(err)
  }
}

function swapPorts() {
  const a = form.value.isp_port
  form.value.isp_port = form.value.cpe_port
  form.value.cpe_port = a
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

onMounted(() => {
  load()
  poll = setInterval(load, 5000)
})
onUnmounted(() => {
  if (poll) clearInterval(poll)
})
</script>

<template>
  <section class="page">
    <header class="page-head">
      <div><h2>系统设置</h2><p>管理路由模式、DNS 与 sing-box 日志级别。模式切换仅设备 Web 可写，须确认，超时回滚。</p></div>
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
      <p v-if="form.proxy_mode === 'gateway'" class="hint">网关 WAN 默认 DHCP。从旁路切回会清除手填的静态地址；透明切回会重新拉起 DHCP。PPPoE/静态仅在保持网关模式时通过「网络 → WAN」页设置。</p>
      <template v-if="form.proxy_mode === 'bypass'">
        <label>旁路 WAN IP<input v-model="form.wan_address" placeholder="例如 10.20.30.2" /></label>
        <label>旁路 WAN 掩码<input v-model="form.wan_netmask" placeholder="例如 255.255.255.0" /></label>
        <label>旁路 WAN 网关<input v-model="form.wan_gateway" placeholder="例如 10.20.30.1" /></label>
        <label>customer_hosts<textarea v-model="form.customer_hosts" rows="3" placeholder="每行一个 IPv4 或 CIDR" /></label>
      </template>
      <template v-if="form.proxy_mode === 'transparent'">
        <p class="hint">isp 接上游、cpe 接客户，编入 br-trans（无互联 IP）。管理 LAN 永不进该桥。已学到客户后不答 CE ARP。</p>
        <label>上游口 isp_port
          <select v-model="form.isp_port">
            <option value="">（选择网卡）</option>
            <option v-for="n in interfaces" :key="'isp-'+n" :value="n">{{ n }}</option>
          </select>
        </label>
        <label>客户口 cpe_port
          <select v-model="form.cpe_port">
            <option value="">（选择网卡）</option>
            <option v-for="n in interfaces" :key="'cpe-'+n" :value="n">{{ n }}</option>
          </select>
        </label>
        <button type="button" @click="swapPorts">对调 isp/cpe</button>
        <p class="hint">学习 {{ textValue(settings.transparent_state, 'idle') }}　CE {{ textValue(settings.learned_ce, '-') }}　GFC DNS {{ textValue(settings.dns_vip, '172.31.253.53') }}</p>
      </template>
      <label class="row"><input type="checkbox" v-model="form.dns_hijack" /> DNS 劫持（三种模式共用；关后 unbound 不停）</label>
      <label>不劫持目的<textarea v-model="form.dns_hijack_exclude" rows="2" placeholder="内网权威 DNS IPv4，每行一个" /></label>
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
          <option value="live_catalog">直播模式 A · 目录分流（ingest → Hy2）</option>
        </select>
      </label>
      <label>国内 DNS<input v-model="form.dns_domestic" placeholder="例如 223.5.5.5" /></label>
      <label>国际 DNS<input v-model="form.dns_intl" placeholder="例如 1.1.1.1" /></label>
      <div v-if="pending" class="pending">
        已申请切换到 {{ pending.to_mode }}，剩余 {{ pending.seconds_left }} 秒未确认将回滚。
        <button type="button" @click="confirmMode">确认网络正常</button>
        <button type="button" @click="rollbackMode">立即回滚</button>
      </div>
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
.page{display:grid;gap:14px}.page-head{display:flex;justify-content:space-between;gap:12px;align-items:center}h2,p{margin:0}p{margin-top:4px;color:var(--muted)}.card{display:grid;gap:10px;background:var(--panel);border:1px solid var(--border);border-radius:10px;padding:12px;max-width:680px}label{display:grid;gap:6px;color:var(--muted)}input,select,textarea{border:1px solid var(--border);border-radius:8px;padding:7px;background:#fff}.row{display:flex;align-items:center;gap:8px}.actions{display:flex;flex-wrap:wrap;gap:8px}button{border:0;border-radius:8px;padding:8px 12px;color:#fff;background:var(--brand);cursor:pointer}.message{color:var(--ok)}.error{color:var(--danger)}.hint{color:var(--muted);font-size:12px}.pending{border:1px solid var(--border);border-radius:8px;padding:8px;display:grid;gap:8px}
</style>
