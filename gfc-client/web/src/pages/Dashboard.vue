<script setup lang="ts">
import { onMounted, onUnmounted, ref } from 'vue'
import { getStatus, getHealth, getDNSStats, getSingboxStats, getAgent } from '../api'

const status = ref<Record<string, unknown>>({})
const health = ref<Record<string, unknown>>({})
const dns = ref<Record<string, unknown>>({})
const singbox = ref<Record<string, unknown>>({})
const agent = ref<Record<string, unknown>>({})
const loading = ref(true)
let timer: ReturnType<typeof setInterval> | undefined

async function load() {
  try {
    const [st, h, d, sb, ag] = await Promise.all([
      getStatus(),
      getHealth(),
      getDNSStats(),
      getSingboxStats(),
      getAgent(),
    ])
    status.value = st
    health.value = h
    dns.value = d
    singbox.value = sb
    agent.value = ag
  } finally {
    loading.value = false
  }
}

function pct(v: unknown) {
  const n = Number(v)
  return Number.isFinite(n) ? n.toFixed(1) + '%' : '—'
}

function badgeClass(active: unknown) {
  return String(active).trim() === 'active' ? 'ok' : 'err'
}

onMounted(() => {
  load()
  timer = setInterval(load, 15000)
})
onUnmounted(() => timer && clearInterval(timer))
</script>

<template>
  <h1 class="page-title">概览</h1>
  <div v-if="loading">加载中…</div>
  <template v-else>
    <div class="grid">
      <div class="card">
        <div class="stat-label">设备状态</div>
        <div class="stat-value">{{ status.state || 'unknown' }}</div>
      </div>
      <div class="card">
        <div class="stat-label">线路 TID</div>
        <div class="stat-value">{{ (status.device as any)?.tid || '—' }}</div>
      </div>
      <div class="card">
        <div class="stat-label">代理模式</div>
        <div class="stat-value">{{ (status.device as any)?.proxy_mode || (agent as any).proxy_mode || 'gateway' }}</div>
      </div>
      <div class="card">
        <div class="stat-label">数据面</div>
        <div class="stat-value">{{ (status.dataplane as any)?.mode || 'idle' }}</div>
      </div>
    </div>

    <div class="card">
      <h3>网络</h3>
      <div class="grid">
        <div>
          <div class="stat-label">WAN</div>
          <div class="stat-value" style="font-size:1rem">{{ (status.network as any)?.wan || '—' }}</div>
        </div>
        <div>
          <div class="stat-label">LAN</div>
          <div class="stat-value" style="font-size:1rem">{{ (status.network as any)?.lan || '—' }}</div>
        </div>
        <div>
          <div class="stat-label">DNS</div>
          <span class="badge" :class="(status.dns as any)?.ok ? 'ok' : 'err'">
            {{ (status.dns as any)?.ok ? 'MosDNS :53' : '异常' }}
          </span>
        </div>
        <div>
          <div class="stat-label">TUN</div>
          <span class="badge" :class="(status.tun as any)?.up ? 'ok' : 'warn'">
            {{ (status.tun as any)?.up ? 'gfctun up' : 'down' }}
          </span>
        </div>
      </div>
    </div>

    <div class="card">
      <h3>系统</h3>
      <div class="grid">
        <div>
          <div class="stat-label">CPU</div>
          <div class="stat-value">{{ pct((status.system as any)?.cpu_percent) }}</div>
        </div>
        <div>
          <div class="stat-label">内存</div>
          <div class="stat-value">{{ pct((status.system as any)?.memory?.used_percent) }}</div>
        </div>
        <div>
          <div class="stat-label">磁盘 /</div>
          <div class="stat-value">{{ pct((status.system as any)?.disk?.used_percent) }}</div>
        </div>
        <div>
          <div class="stat-label">运行时间</div>
          <div class="stat-value" style="font-size:1rem">
            {{ Math.floor(Number((status.system as any)?.uptime_sec || 0) / 3600) }}h
          </div>
        </div>
      </div>
    </div>

    <div class="card">
      <h3>Agent / 控制平台</h3>
      <div class="grid">
        <div>
          <div class="stat-label">配置版本</div>
          <div class="stat-value" style="font-size:1rem">{{ (agent as any).applied_version || '—' }}</div>
        </div>
        <div>
          <div class="stat-label">控制平台</div>
          <span class="badge" :class="(agent as any).cp_reachable ? 'ok' : 'err'">
            {{ (agent as any).cp_reachable ? '可达' : '不可达' }}
          </span>
        </div>
        <div>
          <div class="stat-label">Agent 版本</div>
          <div class="stat-value" style="font-size:1rem">{{ (agent as any).version }}</div>
        </div>
        <div>
          <div class="stat-label">反向 SSH</div>
          <div class="stat-value" style="font-size:1rem">
            {{ (agent as any).reverse_ssh?.enabled ? `:${(agent as any).reverse_ssh_port}` : '未配置' }}
          </div>
        </div>
      </div>
    </div>

    <div class="grid">
      <div class="card">
        <h3>MosDNS</h3>
        <div class="stat-label">近期查询行数</div>
        <div class="stat-value">{{ (dns as any).query_lines ?? '—' }}</div>
      </div>
      <div class="card">
        <h3>Sing-box</h3>
        <div class="stat-label">Clash API</div>
        <span class="badge" :class="(singbox as any).ok ? 'ok' : 'warn'">
          {{ (singbox as any).ok ? '在线' : '未启用/空闲' }}
        </span>
        <div v-if="(singbox as any).connections" class="stat-label" style="margin-top:.5rem">
          连接: {{ Object.keys((singbox as any).connections?.connections || {}).length || (singbox as any).connections?.downloadTotal || '—' }}
        </div>
      </div>
    </div>

    <div class="card">
      <h3>服务健康</h3>
      <div class="grid">
        <div v-for="(svc, name) in health" :key="name">
          <div class="stat-label">{{ name }}</div>
          <span class="badge" :class="badgeClass((svc as any).active)">
            {{ (svc as any).active?.trim() || 'unknown' }}
          </span>
        </div>
      </div>
    </div>
  </template>
</template>
