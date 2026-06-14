<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { getSettings, putSettings, setLogLevel, checkUpgrade } from '../api'

const settings = ref<Record<string, unknown>>({})
const upgrade = ref<Record<string, unknown>>({})
const msg = ref('')

async function load() {
  settings.value = await getSettings()
  upgrade.value = await checkUpgrade()
}

async function save() {
  const res = await putSettings({
    routing_mode: settings.value.routing_mode,
    dns_domestic: settings.value.dns_domestic,
    dns_intl: settings.value.dns_intl,
    proxy_mode: settings.value.proxy_mode,
  })
  msg.value = res.dataplane
    ? `已保存；数据面: ${(res.dataplane as any).message || ''}`
    : '已保存'
}

async function log(level: string) {
  await setLogLevel(level)
  msg.value = `log=${level}`
}

async function refreshUpgrade() {
  upgrade.value = await checkUpgrade()
  msg.value = upgrade.value.update_available ? '有新版本' : '已是最新'
}

onMounted(load)
</script>

<template>
  <h1 class="page-title">设置</h1>
  <div v-if="msg" class="msg">{{ msg }}</div>

  <div class="card">
    <h3>部署模式</h3>
    <label>代理模式（切换后重载网络 + 数据面）</label>
    <select v-model="settings.proxy_mode" style="margin: .5rem 0">
      <option value="gateway">gateway 网关</option>
      <option value="bypass">bypass 旁路</option>
      <option value="transparent">transparent 透明</option>
    </select>
  </div>

  <div class="card">
    <h3>路由与 DNS</h3>
    <label>路由模式</label>
    <select v-model="settings.routing_mode" style="margin: .5rem 0">
      <option value="split">split</option>
      <option value="global">global</option>
    </select>
    <label>国内 DNS</label>
    <input v-model="settings.dns_domestic" style="margin: .5rem 0" />
    <label>国际 DNS</label>
    <input v-model="settings.dns_intl" style="margin: .5rem 0" />
    <button class="btn" @click="save">保存</button>
  </div>

  <div class="card">
    <h3>sing-box 日志</h3>
    <button class="btn secondary" @click="log('error')">error</button>
    <button class="btn secondary" style="margin-left: .5rem" @click="log('info')">info</button>
    <button class="btn secondary" style="margin-left: .5rem" @click="log('debug')">debug</button>
  </div>

  <div class="card">
    <h3>升级</h3>
    <div class="stat-label">当前版本</div>
    <div class="stat-value" style="font-size:1rem">{{ upgrade.current || '—' }}</div>
    <div v-if="upgrade.latest" class="stat-label" style="margin-top:.5rem">最新版本</div>
    <div v-if="upgrade.latest" class="stat-value" style="font-size:1rem">{{ upgrade.latest }}</div>
    <button class="btn secondary" style="margin-top:.75rem" @click="refreshUpgrade">检查更新</button>
  </div>
</template>
