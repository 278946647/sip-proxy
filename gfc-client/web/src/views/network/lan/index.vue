<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import ConfigPanel from '@/components/business/ConfigPanel.vue'
import JsonBlock from '@/components/common/JsonBlock.vue'
import { networkApi } from '@/api/network'
import { bridgeMembers, interfaceNames } from '../shared'
import { textValue } from '@/utils/data'

const loading = ref(false)
const saving = ref(false)
const message = ref('')
const error = ref('')
const bridge = ref<Record<string, unknown>>({})
const interfaces = ref<Record<string, unknown>>({})

const form = ref({
  bridgeName: 'bridge_lan',
  mode: 'bridge',
  lanAddress: '192.168.68.1',
  lanPrefix: 24,
  members: [] as string[],
  dhcpEnabled: true,
  dhcpStart: '192.168.68.100',
  dhcpEnd: '192.168.68.199',
})

const names = computed(() => interfaceNames(interfaces.value))

async function load() {
  loading.value = true
  error.value = ''
  try {
    const [bridgeRes, interfacesRes] = await Promise.all([networkApi.bridge(), networkApi.interfaces()])
    if (bridgeRes.ok) {
      bridge.value = bridgeRes.data
      form.value.bridgeName = textValue(bridgeRes.data.bridgeName || bridgeRes.data.bridge_name || bridgeRes.data.name, form.value.bridgeName)
      form.value.mode = textValue(bridgeRes.data.mode, form.value.mode)
      form.value.lanAddress = textValue(bridgeRes.data.lanAddress || bridgeRes.data.lan_address, form.value.lanAddress)
      form.value.lanPrefix = Number(bridgeRes.data.lanPrefix || bridgeRes.data.lan_prefix || form.value.lanPrefix)
      form.value.members = bridgeMembers(bridgeRes.data)
      form.value.dhcpEnabled = Boolean(bridgeRes.data.dhcpEnabled ?? bridgeRes.data.dhcp_enabled ?? form.value.dhcpEnabled)
      form.value.dhcpStart = textValue(bridgeRes.data.dhcpStart || bridgeRes.data.dhcp_start, form.value.dhcpStart)
      form.value.dhcpEnd = textValue(bridgeRes.data.dhcpEnd || bridgeRes.data.dhcp_end, form.value.dhcpEnd)
    }
    if (interfacesRes.ok) interfaces.value = interfacesRes.data
  } catch (err) {
    error.value = String(err)
  } finally {
    loading.value = false
  }
}

function toggleMember(name: string) {
  if (form.value.members.includes(name)) {
    form.value.members = form.value.members.filter((item) => item !== name)
  } else {
    form.value.members = [...form.value.members, name]
  }
}

async function save() {
  saving.value = true
  message.value = ''
  try {
    const payload = {
      bridgeName: form.value.bridgeName,
      bridge_name: form.value.bridgeName,
      mode: form.value.mode,
      lanAddress: form.value.lanAddress,
      lan_address: form.value.lanAddress,
      lanPrefix: form.value.lanPrefix,
      lan_prefix: form.value.lanPrefix,
      members: form.value.members,
      dhcpEnabled: form.value.dhcpEnabled,
      dhcp_enabled: form.value.dhcpEnabled,
      dhcpStart: form.value.dhcpStart,
      dhcp_start: form.value.dhcpStart,
      dhcpEnd: form.value.dhcpEnd,
      dhcp_end: form.value.dhcpEnd,
    }
    const res = await networkApi.updateBridge(payload)
    message.value = res.ok ? 'LAN / 桥接配置已提交，后端将应用网络配置。' : (res.error?.message ?? '保存失败')
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
      <div><h2>LAN / 桥接</h2><p>配置内网桥、网关地址、成员接口与 DHCP 地址池。</p></div>
      <button :disabled="loading" @click="load">{{ loading ? '刷新中...' : '刷新' }}</button>
    </header>
    <div v-if="message" class="notice">{{ message }}</div>
    <div v-if="error" class="error">{{ error }}</div>

    <ConfigPanel title="LAN 接口">
      <div class="form-grid">
        <label>桥名称 <input v-model="form.bridgeName" /></label>
        <label>模式
          <select v-model="form.mode">
            <option value="bridge">桥接</option>
            <option value="routed">路由口</option>
          </select>
        </label>
        <label>LAN 地址 <input v-model="form.lanAddress" /></label>
        <label>前缀长度 <input v-model.number="form.lanPrefix" type="number" min="1" max="32" /></label>
      </div>
    </ConfigPanel>

    <ConfigPanel title="桥成员接口">
      <div class="members">
        <label v-for="name in names" :key="name" class="member">
          <input :checked="form.members.includes(name)" type="checkbox" @change="toggleMember(name)" />
          {{ name }}
        </label>
      </div>
    </ConfigPanel>

    <ConfigPanel title="DHCP 地址池">
      <div class="form-grid">
        <label class="switch"><input v-model="form.dhcpEnabled" type="checkbox" /> 启用 DHCP</label>
        <label>起始地址 <input v-model="form.dhcpStart" /></label>
        <label>结束地址 <input v-model="form.dhcpEnd" /></label>
      </div>
    </ConfigPanel>

    <div class="actions">
      <button :disabled="saving" @click="save">{{ saving ? '保存中...' : '保存并应用 LAN 配置' }}</button>
    </div>

    <JsonBlock title="当前桥接配置 /network/bridge" :data="bridge" />
  </section>
</template>

<style scoped>
.page{display:grid;gap:12px}.page-head{display:flex;justify-content:space-between;align-items:center;gap:12px}h2,p{margin:0}p{margin-top:4px;color:var(--muted)}button{border:0;border-radius:4px;padding:7px 12px;color:#fff;background:#2563eb;cursor:pointer}.form-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:12px}label{display:grid;gap:5px;color:#334155;font-size:13px}.switch,.member{display:flex;align-items:center;gap:8px}.members{display:flex;gap:10px;flex-wrap:wrap}input,select{border:1px solid var(--border);border-radius:4px;padding:7px;background:#fff}.actions{display:flex;justify-content:flex-end}.notice{padding:8px 10px;border:1px solid #bbf7d0;background:#f0fdf4;color:#15803d;border-radius:4px}.error{color:var(--danger)}
</style>
