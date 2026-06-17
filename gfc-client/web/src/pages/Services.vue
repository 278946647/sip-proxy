<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { getServices, restartService, reloadDataplane } from '../api'
import api from '../api'

const services = ref<Record<string, unknown>>({})
const msg = ref('')

async function rollback() {
  const { data } = await api.post('/dataplane/rollback')
  msg.value = data.data?.message as string
  await load()
}

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
  <button class="btn secondary" style="margin-left: .5rem" @click="rollback">回滚上一快照</button>
  <p class="hint" style="margin-top:.5rem;color:var(--muted,#888);font-size:.9rem">
    回滚后自动按当前模板重渲染并刷新 WAN 绑定与 policy 路由。若仍异常请点「重载数据面」。
  </p>
  <div class="card" v-for="(svc, name) in services" :key="String(name)" style="margin-top: 1rem">
    <strong>{{ name }}</strong>
    <span class="badge" :class="(svc as any).active?.trim() === 'active' ? 'ok' : 'err'" style="margin-left: .5rem">
      {{ (svc as any).active?.trim() }}
    </span>
    <button class="btn secondary" style="margin-left: 1rem" @click="restart(String(name))">重启</button>
  </div>
</template>
