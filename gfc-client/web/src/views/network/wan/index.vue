<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import ConfigPanel from '@/components/business/ConfigPanel.vue'
import JsonBlock from '@/components/common/JsonBlock.vue'
import { networkApi } from '@/api/network'
import { interfaceNames, networkWan } from '../shared'

const loading = ref(false)
const saving = ref(false)
const message = ref('')
const error = ref('')
const network = ref<Record<string, unknown>>({})
const wan = ref<Record<string, unknown>>({})
const interfaces = ref<Record<string, unknown>>({})

const form = ref({
  enabled: true,
  interface: 'ens160',
  mode: 'dhcp',
  address: '',
  netmask: '255.255.255.0',
  gateway: '',
  dns1: '',
  dns2: '',
  pppoeUsername: '',
  pppoePassword: '',
  mtu: 1500,
})

const names = computed(() => interfaceNames(interfaces.value))

async function load() {
  loading.value = true
  error.value = ''
  try {
    const [networkRes, wanRes, interfacesRes] = await Promise.all([networkApi.summary(), networkApi.wan(), networkApi.interfaces()])
    if (networkRes.ok) {
      network.value = networkRes.data
      form.value.interface = networkWan(networkRes.data)
    }
    if (wanRes.ok) {
      wan.value = wanRes.data
      form.value.enabled = Boolean(wanRes.data.enabled ?? form.value.enabled)
      form.value.interface = String(wanRes.data.interface || form.value.interface)
      form.value.mode = String(wanRes.data.mode || form.value.mode)
      form.value.address = String(wanRes.data.address || '')
      form.value.netmask = String(wanRes.data.netmask || '')
      form.value.gateway = String(wanRes.data.gateway || '')
      form.value.dns1 = String(wanRes.data.dns1 || '')
      form.value.dns2 = String(wanRes.data.dns2 || '')
      form.value.pppoeUsername = String(wanRes.data.pppoeUsername || wanRes.data.pppoe_username || '')
      form.value.pppoePassword = String(wanRes.data.pppoePassword || wanRes.data.pppoe_password || '')
      form.value.mtu = Number(wanRes.data.mtu || form.value.mtu)
    }
    if (interfacesRes.ok) interfaces.value = interfacesRes.data
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
    const res = await networkApi.updateWan({
      ...form.value,
      pppoe_username: form.value.pppoeUsername,
      pppoe_password: form.value.pppoePassword,
    })
    message.value = res.ok ? 'WAN 配置已保存并触发网络应用。' : (res.error?.message ?? '保存失败')
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
      <div>
        <h2>WAN 配置</h2>
        <p>配置外网接口、地址获取方式、网关、DNS 与 MTU。</p>
      </div>
      <button :disabled="loading" @click="load">{{ loading ? '刷新中...' : '刷新' }}</button>
    </header>

    <div v-if="message" class="notice">{{ message }}</div>
    <div v-if="error" class="error">{{ error }}</div>

    <ConfigPanel title="接口设置" description="对应上联口，常见模式为 DHCP、静态 IP 或 PPPoE。">
      <div class="form-grid">
        <label class="switch"><input v-model="form.enabled" type="checkbox" /> 启用 WAN</label>
        <label>接口
          <select v-model="form.interface">
            <option v-for="item in names" :key="item" :value="item">{{ item }}</option>
            <option v-if="!names.includes(form.interface)" :value="form.interface">{{ form.interface }}</option>
          </select>
        </label>
        <label>地址模式
          <select v-model="form.mode">
            <option value="dhcp">DHCP</option>
            <option value="static">静态 IP</option>
            <option value="pppoe">PPPoE</option>
          </select>
        </label>
        <label>MTU <input v-model.number="form.mtu" type="number" min="576" max="9000" /></label>
      </div>
    </ConfigPanel>

    <ConfigPanel v-if="form.mode === 'static'" title="静态地址">
      <div class="form-grid">
        <label>IP 地址 <input v-model="form.address" placeholder="192.0.2.10" /></label>
        <label>子网掩码 <input v-model="form.netmask" placeholder="255.255.255.0" /></label>
        <label>默认网关 <input v-model="form.gateway" placeholder="192.0.2.1" /></label>
        <label>首选 DNS <input v-model="form.dns1" placeholder="223.5.5.5" /></label>
        <label>备用 DNS <input v-model="form.dns2" placeholder="1.1.1.1" /></label>
      </div>
    </ConfigPanel>

    <ConfigPanel v-if="form.mode === 'pppoe'" title="PPPoE 拨号">
      <div class="form-grid">
        <label>用户名 <input v-model="form.pppoeUsername" autocomplete="off" /></label>
        <label>密码 <input v-model="form.pppoePassword" type="password" autocomplete="new-password" /></label>
      </div>
    </ConfigPanel>

    <ConfigPanel title="应用预览">
      <div class="actions">
        <button :disabled="saving" @click="save">{{ saving ? '保存中...' : '保存 WAN 配置' }}</button>
        <span>保存后写入设备网络配置并调用现有网络应用脚本。</span>
      </div>
    </ConfigPanel>

    <JsonBlock title="当前 WAN 配置 /network/wan" :data="wan" />
    <JsonBlock title="当前网络状态 /network" :data="network" />
  </section>
</template>

<style scoped>
.page{display:grid;gap:12px}.page-head{display:flex;justify-content:space-between;align-items:center;gap:12px}h2,p{margin:0}p{margin-top:4px;color:var(--muted)}button{border:0;border-radius:4px;padding:7px 12px;color:#fff;background:#2563eb;cursor:pointer}.form-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:12px}label{display:grid;gap:5px;color:#334155;font-size:13px}.switch{display:flex;align-items:center;gap:8px}input,select{border:1px solid var(--border);border-radius:4px;padding:7px;background:#fff}.actions{display:flex;gap:10px;align-items:center;flex-wrap:wrap;color:var(--muted)}.notice{padding:8px 10px;border:1px solid #bfdbfe;background:#eff6ff;color:#1d4ed8;border-radius:4px}.error{color:var(--danger)}
</style>
