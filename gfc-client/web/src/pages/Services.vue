<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { getServices, restartService, reloadDataplane } from '../api'

const services = ref<Record<string, unknown>>({})
const msg = ref('')

async function load() {
  services.value = await getServices()
}

async function restart(name: string) {
  const r = await restartService(name)
  msg.value = r.message as string
  await load()
}

async function reload() {
  const r = await reloadDataplane()
  msg.value = r.message as string
}

onMounted(load)
</script>

<template>
  <h1 class="page-title">服务管理</h1>
  <div v-if="msg" class="msg">{{ msg }}</div>
  <button class="btn" @click="reload">重载数据面</button>
  <div class="card" v-for="(svc, name) in services" :key="String(name)" style="margin-top: 1rem">
    <strong>{{ name }}</strong>
    <span class="badge" :class="(svc as any).active?.trim() === 'active' ? 'ok' : 'err'" style="margin-left: .5rem">
      {{ (svc as any).active?.trim() }}
    </span>
    <button class="btn secondary" style="margin-left: 1rem" @click="restart(String(name))">重启</button>
  </div>
</template>
