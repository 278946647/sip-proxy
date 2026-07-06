<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import JsonBlock from '@/components/common/JsonBlock.vue'
import DataTable from '@/components/common/DataTable.vue'
import StatCard from '@/components/common/StatCard.vue'
import { overviewApi } from '@/api/overview'
import { connectivityApi } from '@/api/connectivity'
import { maintenanceApi } from '@/api/maintenance'
import { asArray, asRecord, textValue } from '@/utils/data'

const loading = ref(false)
const error = ref('')
const status = ref<Record<string, unknown>>({})
const health = ref<Record<string, unknown>>({})
const metrics = ref<Record<string, unknown>>({})
const dnsStats = ref<Record<string, unknown>>({})
const forwardStats = ref<Record<string, unknown>>({})
const alerts = ref<Record<string, unknown>>({})

const device = computed(() => asRecord(status.value.device))
const system = computed(() => asRecord(status.value.system))
const network = computed(() => asRecord(status.value.network))
const tun = computed(() => asRecord(status.value.tun))
const dns = computed(() => asRecord(status.value.dns))
const agent = computed(() => asRecord(status.value.agent))
const serviceRows = computed(() => Object.entries(health.value).map(([name, value]) => ({ name, ...asRecord(value) })))
const alertRows = computed(() => asArray(alerts.value.alerts).map(asRecord))

async function load() {
  loading.value = true
  error.value = ''
  try {
    const [statusRes, healthRes, metricsRes, dnsStatsRes, forwardStatsRes, agentRes, alertsRes] = await Promise.all([
      overviewApi.status(),
      overviewApi.health(),
      overviewApi.metrics(),
      maintenanceApi.dnsStats(),
      maintenanceApi.singboxStats(),
      connectivityApi.agent(),
      overviewApi.alerts(),
    ])
    if (statusRes.ok) status.value = statusRes.data
    if (healthRes.ok) health.value = healthRes.data
    if (metricsRes.ok) metrics.value = metricsRes.data
    if (dnsStatsRes.ok) dnsStats.value = dnsStatsRes.data
    if (forwardStatsRes.ok) forwardStats.value = forwardStatsRes.data
    if (agentRes.ok) status.value = { ...status.value, agent: agentRes.data }
    if (alertsRes.ok) alerts.value = alertsRes.data
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
      <div>
        <h2>Dashboard</h2>
        <p>设备运行状态、网络、Unbound DNS、TUN 与 Agent 汇总。</p>
      </div>
      <button :disabled="loading" @click="load">{{ loading ? '刷新中...' : '刷新' }}</button>
    </header>

    <div v-if="error" class="error">{{ error }}</div>

    <div class="cards">
      <StatCard label="激活状态" :value="textValue(status.state)" :tone="status.state === 'active' ? 'ok' : 'warn'" />
      <StatCard label="设备名称" :value="textValue(device.name || device.device_name || device.id)" />
      <StatCard label="CPU" :value="textValue(system.cpu || system.cpu_percent)" />
      <StatCard label="内存" :value="textValue(system.memory || system.mem_percent)" />
      <StatCard label="网络模式" :value="textValue(network.mode || network.proxy_mode)" />
      <StatCard label="TUN" :value="textValue(tun.up || tun.status)" :tone="tun.up ? 'ok' : 'normal'" />
      <StatCard label="Unbound" :value="textValue(dns.ok || dns.status)" :tone="dns.ok ? 'ok' : 'normal'" />
      <StatCard label="Agent" :value="textValue(agent.status || agent.state)" />
    </div>

    <div class="main-grid">
      <section class="panel">
        <h3>服务健康</h3>
        <DataTable :columns="[
          { key: 'name', title: '服务' },
          { key: 'unit', title: 'Unit' },
          { key: 'active', title: 'Active' },
          { key: 'sub', title: 'SubState' },
        ]" :rows="serviceRows" />
      </section>
      <section class="panel">
        <h3>告警</h3>
        <DataTable :columns="[
          { key: 'severity', title: '级别' },
          { key: 'source', title: '来源' },
          { key: 'title', title: '标题' },
          { key: 'message', title: '说明' },
        ]" :rows="alertRows" empty-text="当前没有告警" />
      </section>
    </div>

    <div class="grid">
      <JsonBlock title="状态详情 /status" :data="status" />
      <JsonBlock title="服务健康 /health" :data="health" />
      <JsonBlock title="指标快照 /metrics" :data="metrics" />
      <JsonBlock title="Unbound 统计 /dns/stats" :data="dnsStats" />
      <JsonBlock title="转发统计 /singbox/stats" :data="forwardStats" />
      <JsonBlock title="告警调试 /alerts" :data="alerts" />
    </div>
  </section>
</template>

<style scoped>
.page {
  display: grid;
  gap: 14px;
}

.page-head {
  display: flex;
  justify-content: space-between;
  gap: 12px;
  align-items: center;
}

h2,
p {
  margin: 0;
}

p {
  margin-top: 4px;
  color: var(--muted);
}

button {
  border: 0;
  border-radius: 8px;
  padding: 8px 12px;
  color: #fff;
  background: var(--brand);
  cursor: pointer;
}

.cards {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(160px, 1fr));
  gap: 10px;
}

.grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
  gap: 12px;
}

.main-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(360px, 1fr));
  gap: 12px;
}

.panel {
  display: grid;
  gap: 8px;
}

.panel h3 {
  margin: 0;
  font-size: 15px;
}

.error {
  color: var(--danger);
}
</style>
