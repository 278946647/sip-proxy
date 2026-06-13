<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { getNetwork } from '../api'

const net = ref<Record<string, unknown>>({})
onMounted(async () => { net.value = await getNetwork() })
</script>

<template>
  <h1 class="page-title">网络</h1>
  <div class="grid">
    <div class="card"><div class="stat-label">WAN</div><div class="stat-value">{{ net.wan || '—' }}</div></div>
    <div class="card"><div class="stat-label">LAN</div><div class="stat-value">{{ net.lan || '—' }}</div></div>
    <div class="card"><div class="stat-label">网关</div><div class="stat-value">{{ net.gateway || '—' }}</div></div>
  </div>
  <div class="card">
    <h3>网卡</h3>
    <pre>{{ (net.interfaces as string[])?.join('\n') }}</pre>
  </div>
</template>
