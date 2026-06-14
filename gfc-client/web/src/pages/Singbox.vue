<script setup lang="ts">
import { onMounted, onUnmounted, ref } from 'vue'
import { getSingboxStats, getHealth } from '../api'

const stats = ref<Record<string, unknown>>({})
const health = ref<Record<string, unknown>>({})
const loading = ref(true)
let timer: ReturnType<typeof setInterval> | undefined

async function load() {
  try {
    stats.value = await getSingboxStats()
    health.value = await getHealth()
  } finally {
    loading.value = false
  }
}

function fmtBytes(v: unknown) {
  const n = Number(v)
  if (!Number.isFinite(n)) return '—'
  if (n < 1024) return n + ' B'
  if (n < 1048576) return (n / 1024).toFixed(1) + ' KB'
  return (n / 1048576).toFixed(1) + ' MB'
}

onMounted(() => {
  load()
  timer = setInterval(load, 10000)
})
onUnmounted(() => timer && clearInterval(timer))
</script>

<template>
  <h1 class="page-title">Sing-box</h1>
  <div v-if="loading">加载中…</div>
  <template v-else>
    <div class="grid">
      <div class="card">
        <div class="stat-label">TUN 服务</div>
        <span class="badge" :class="(health['sing-box'] as any)?.active?.trim() === 'active' ? 'ok' : 'err'">
          {{ (health['sing-box'] as any)?.active || 'unknown' }}
        </span>
      </div>
      <div class="card">
        <div class="stat-label">Clash API</div>
        <span class="badge" :class="stats.ok ? 'ok' : 'warn'">{{ stats.ok ? '可达' : '不可用' }}</span>
      </div>
      <div class="card">
        <div class="stat-label">接口</div>
        <div class="stat-value" style="font-size:1rem">gfctun</div>
      </div>
    </div>

    <div v-if="stats.traffic" class="card">
      <h3>流量</h3>
      <div class="grid">
        <div>
          <div class="stat-label">上行</div>
          <div class="stat-value" style="font-size:1rem">{{ fmtBytes((stats.traffic as any).up) }}</div>
        </div>
        <div>
          <div class="stat-label">下行</div>
          <div class="stat-value" style="font-size:1rem">{{ fmtBytes((stats.traffic as any).down) }}</div>
        </div>
      </div>
    </div>

    <div v-if="stats.connections" class="card">
      <h3>当前连接</h3>
      <pre class="log">{{ JSON.stringify(stats.connections, null, 2) }}</pre>
    </div>

    <div v-if="stats.memory" class="card">
      <h3>内存</h3>
      <pre class="log">{{ JSON.stringify(stats.memory, null, 2) }}</pre>
    </div>

    <div v-if="!stats.ok" class="card">
      <p style="color:var(--muted);margin:0">
        空闲模式或未激活时 Clash API 不可用；激活线路后 sing-box 将监听 127.0.0.1:9090。
      </p>
      <p v-if="stats.error" class="msg">{{ stats.error }}</p>
    </div>
  </template>
</template>
