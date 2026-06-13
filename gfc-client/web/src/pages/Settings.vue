<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { getSettings, putSettings, setLogLevel } from '../api'

const settings = ref<Record<string, unknown>>({})
const msg = ref('')

async function load() {
  settings.value = await getSettings()
}

async function save() {
  await putSettings({
    routing_mode: settings.value.routing_mode,
    dns_domestic: settings.value.dns_domestic,
    dns_intl: settings.value.dns_intl,
  })
  msg.value = '已保存'
}

async function log(level: string) {
  await setLogLevel(level)
  msg.value = `log=${level}`
}

onMounted(load)
</script>

<template>
  <h1 class="page-title">设置</h1>
  <div v-if="msg" class="msg">{{ msg }}</div>
  <div class="card">
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
</template>
