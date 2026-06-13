<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { getStatus, getHealth } from '../api'

const status = ref<Record<string, unknown>>({})
const health = ref<Record<string, unknown>>({})
const loading = ref(true)

onMounted(async () => {
  try {
    status.value = await getStatus()
    health.value = await getHealth()
  } finally {
    loading.value = false
  }
})
</script>

<template>
  <h1 class="page-title">概览</h1>
  <div v-if="loading">加载中…</div>
  <template v-else>
    <div class="grid">
      <div class="card">
        <div class="stat-label">状态</div>
        <div class="stat-value">{{ status.state || 'unknown' }}</div>
      </div>
      <div class="card">
        <div class="stat-label">线路 TID</div>
        <div class="stat-value">{{ (status.device as any)?.tid || '—' }}</div>
      </div>
      <div class="card">
        <div class="stat-label">代理模式</div>
        <div class="stat-value">{{ (status.device as any)?.proxy_mode || 'gateway' }}</div>
      </div>
      <div class="card">
        <div class="stat-label">数据面</div>
        <div class="stat-value">{{ (status.dataplane as any)?.mode || 'idle' }}</div>
      </div>
    </div>
    <div class="card">
      <h3>服务健康</h3>
      <div class="grid">
        <div v-for="(svc, name) in health" :key="name">
          <div class="stat-label">{{ name }}</div>
          <span class="badge" :class="(svc as any).active?.trim() === 'active' ? 'ok' : 'err'">
            {{ (svc as any).active?.trim() || 'unknown' }}
          </span>
        </div>
      </div>
    </div>
  </template>
</template>
