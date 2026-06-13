<script setup lang="ts">
import { ref } from 'vue'
import { getLogs } from '../api'

const service = ref('agent')
const lines = ref<string[]>([])

async function load() {
  const r = await getLogs(service.value, 300)
  lines.value = (r.lines as string[]) || []
}
</script>

<template>
  <h1 class="page-title">日志</h1>
  <div class="card">
    <select v-model="service" @change="load">
      <option value="agent">agent</option>
      <option value="api">api</option>
      <option value="sing-box">sing-box</option>
      <option value="mosdns">mosdns</option>
    </select>
    <button class="btn secondary" style="margin-left: .5rem" @click="load">刷新</button>
  </div>
  <pre class="log">{{ lines.join('\n') || '暂无日志' }}</pre>
</template>
