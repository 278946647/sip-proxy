<script setup lang="ts">
import { onMounted, ref } from 'vue'
import ConfigPanel from '@/components/business/ConfigPanel.vue'
import JsonBlock from '@/components/common/JsonBlock.vue'
import { networkApi } from '@/api/network'
import { textValue } from '@/utils/data'

const loading = ref(false)
const saving = ref(false)
const message = ref('')
const error = ref('')
const bridge = ref<Record<string, unknown>>({})

const form = ref({
  enabled: true,
  gateway: '192.168.68.1',
  start: '192.168.68.100',
  end: '192.168.68.199',
  leaseTime: '12h',
  dns: '192.168.68.1',
  domain: 'lan',
})

async function load() {
  loading.value = true
  error.value = ''
  try {
    const res = await networkApi.bridge()
    if (res.ok) {
      bridge.value = res.data
      form.value.enabled = Boolean(res.data.dhcpEnabled ?? res.data.dhcp_enabled ?? form.value.enabled)
      form.value.gateway = textValue(res.data.lanAddress || res.data.lan_address, form.value.gateway)
      form.value.start = textValue(res.data.dhcpStart || res.data.dhcp_start, form.value.start)
      form.value.end = textValue(res.data.dhcpEnd || res.data.dhcp_end, form.value.end)
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
    const payload = {
      ...bridge.value,
      lanAddress: form.value.gateway,
      lan_address: form.value.gateway,
      dhcpEnabled: form.value.enabled,
      dhcp_enabled: form.value.enabled,
      dhcpStart: form.value.start,
      dhcp_start: form.value.start,
      dhcpEnd: form.value.end,
      dhcp_end: form.value.end,
      dhcpLeaseTime: form.value.leaseTime,
      dhcp_lease_time: form.value.leaseTime,
      dhcpDns: form.value.dns,
      dhcp_dns: form.value.dns,
      dhcpDomain: form.value.domain,
      dhcp_domain: form.value.domain,
    }
    const res = await networkApi.updateBridge(payload)
    message.value = res.ok ? 'DHCP 参数已提交到网络配置。' : (res.error?.message ?? '保存失败')
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
      <div><h2>DHCP 服务</h2><p>配置 LAN 侧地址池、网关、DNS 和租约时间。</p></div>
      <button :disabled="loading" @click="load">{{ loading ? '刷新中...' : '刷新' }}</button>
    </header>
    <div v-if="message" class="notice">{{ message }}</div>
    <div v-if="error" class="error">{{ error }}</div>
    <ConfigPanel title="DHCP Server">
      <div class="form-grid">
        <label class="switch"><input v-model="form.enabled" type="checkbox" /> 启用 DHCP</label>
        <label>网关地址 <input v-model="form.gateway" /></label>
        <label>起始地址 <input v-model="form.start" /></label>
        <label>结束地址 <input v-model="form.end" /></label>
        <label>DNS 服务器 <input v-model="form.dns" /></label>
        <label>租约时间 <input v-model="form.leaseTime" placeholder="12h" /></label>
        <label>本地域 <input v-model="form.domain" placeholder="lan" /></label>
      </div>
    </ConfigPanel>
    <div class="actions">
      <button :disabled="saving" @click="save">{{ saving ? '保存中...' : '保存 DHCP 配置' }}</button>
    </div>
    <JsonBlock title="当前 DHCP/桥接原始配置" :data="bridge" />
  </section>
</template>

<style scoped>
.page{display:grid;gap:12px}.page-head{display:flex;justify-content:space-between;align-items:center;gap:12px}h2,p{margin:0}p{margin-top:4px;color:var(--muted)}button{border:0;border-radius:4px;padding:7px 12px;color:#fff;background:#2563eb;cursor:pointer}.form-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:12px}label{display:grid;gap:5px;color:#334155;font-size:13px}.switch{display:flex;align-items:center;gap:8px}input{border:1px solid var(--border);border-radius:4px;padding:7px;background:#fff}.actions{display:flex;justify-content:flex-end}.notice{padding:8px 10px;border:1px solid #bbf7d0;background:#f0fdf4;color:#15803d;border-radius:4px}.error{color:var(--danger)}
</style>
