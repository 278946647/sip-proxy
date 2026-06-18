<script setup lang="ts">
import { onMounted, ref } from 'vue'
import JsonBlock from '@/components/common/JsonBlock.vue'
import StatCard from '@/components/common/StatCard.vue'
import { connectivityApi } from '@/api/connectivity'
import { textValue } from '@/utils/data'

const loading = ref(false)
const error = ref('')
const agent = ref<Record<string, unknown>>({})

async function load() {
  loading.value = true
  error.value = ''
  try {
    const res = await connectivityApi.agent()
    if (res.ok) agent.value = res.data
  } catch (err) {
    error.value = String(err)
  } finally {
    loading.value = false
  }
}

onMounted(load)
</script>

<template>
  <section class="page">
    <header class="page-head">
      <div><h2>Agent 同步状态</h2><p>显示 Agent、反向 SSH 与控制平台同步信息。</p></div>
      <button :disabled="loading" @click="load">刷新</button>
    </header>
    <p v-if="error" class="error">{{ error }}</p>
    <div class="cards">
      <StatCard label="状态" :value="textValue(agent.status || agent.state)" />
      <StatCard label="设备" :value="textValue(agent.device)" />
      <StatCard label="反向 SSH" :value="textValue(agent.reverse_ssh)" />
      <StatCard label="SSH 端口" :value="textValue(agent.reverse_ssh_port)" />
    </div>
    <JsonBlock title="Agent 原始响应 /agent" :data="agent" />
  </section>
</template>

<style scoped>
.page{display:grid;gap:14px}.page-head{display:flex;justify-content:space-between;gap:12px;align-items:center}h2,p{margin:0}p{margin-top:4px;color:var(--muted)}button{border:0;border-radius:8px;padding:8px 12px;color:#fff;background:var(--brand);cursor:pointer}.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));gap:10px}.error{color:var(--danger)}
</style>
