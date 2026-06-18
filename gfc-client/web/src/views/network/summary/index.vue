<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import JsonBlock from '@/components/common/JsonBlock.vue'
import StatCard from '@/components/common/StatCard.vue'
import { networkApi } from '@/api/network'
import { asArray, textValue } from '@/utils/data'
import { bridgeMembers, interfaceNames, networkLan, networkWan } from '../shared'

const loading = ref(false)
const error = ref('')
const summary = ref<Record<string, unknown>>({})
const interfaces = ref<Record<string, unknown>>({})
const bridge = ref<Record<string, unknown>>({})

const names = computed(() => interfaceNames(interfaces.value))
const rows = computed(() => asArray(interfaces.value.interfaces).map((item) => ({ name: textValue(item) })))

async function load() {
  loading.value = true
  error.value = ''
  try {
    const [summaryRes, interfacesRes, bridgeRes] = await Promise.all([
      networkApi.summary(),
      networkApi.interfaces(),
      networkApi.bridge(),
    ])
    if (summaryRes.ok) summary.value = summaryRes.data
    if (interfacesRes.ok) interfaces.value = interfacesRes.data
    if (bridgeRes.ok) bridge.value = bridgeRes.data
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
        <h2>网络总览</h2>
        <p>展示当前 WAN/LAN、接口与桥接配置。写入配置后续拆到 WAN/LAN 子页。</p>
      </div>
      <button :disabled="loading" @click="load">{{ loading ? '刷新中...' : '刷新' }}</button>
    </header>
    <div v-if="error" class="error">{{ error }}</div>
    <div class="cards">
      <StatCard label="WAN 接口" :value="networkWan(summary)" />
      <StatCard label="LAN 接口" :value="networkLan(summary)" />
      <StatCard label="桥名称" :value="textValue(bridge.bridgeName || bridge.bridge_name || bridge.name)" />
      <StatCard label="LAN 地址" :value="textValue(bridge.lanAddress || bridge.lan_address)" />
      <StatCard label="DHCP" :value="textValue(bridge.dhcpEnabled ?? bridge.dhcp_enabled)" />
      <StatCard label="接口数量" :value="String(names.length)" />
    </div>

    <div class="layout-grid">
      <section class="card">
        <h3>接口列表</h3>
        <table>
          <thead><tr><th>接口</th><th>角色</th></tr></thead>
          <tbody>
            <tr v-for="row in rows" :key="row.name">
              <td>{{ row.name }}</td>
              <td>
                <span v-if="row.name === networkWan(summary)" class="badge wan">WAN</span>
                <span v-else-if="bridgeMembers(bridge).includes(row.name)" class="badge lan">LAN</span>
                <span v-else class="badge">未分配</span>
              </td>
            </tr>
          </tbody>
        </table>
      </section>
      <section class="card">
        <h3>桥接成员</h3>
        <div class="chips">
          <span v-for="item in bridgeMembers(bridge)" :key="item">{{ item }}</span>
          <em v-if="!bridgeMembers(bridge).length">暂无成员</em>
        </div>
      </section>
    </div>

    <div class="grid">
      <JsonBlock title="网络状态 /network" :data="summary" />
      <JsonBlock title="桥接配置 /network/bridge" :data="bridge" />
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

.grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
  gap: 12px;
}

.cards {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
  gap: 10px;
}

.layout-grid {
  display: grid;
  grid-template-columns: minmax(360px, 1.2fr) minmax(240px, .8fr);
  gap: 12px;
}

.card {
  background: var(--panel);
  border: 1px solid var(--border);
  border-radius: 4px;
  overflow: auto;
}

.card h3 {
  margin: 0;
  padding: 10px 12px;
  background: #f8fafc;
  border-bottom: 1px solid var(--border);
  font-size: 14px;
}

table {
  width: 100%;
  border-collapse: collapse;
}

th,
td {
  padding: 8px 10px;
  border-bottom: 1px solid var(--border);
  text-align: left;
}

.badge,
.chips span {
  display: inline-flex;
  border-radius: 999px;
  padding: 2px 8px;
  background: #e5e7eb;
  color: #334155;
  font-size: 12px;
}

.badge.wan {
  background: #dbeafe;
  color: #1d4ed8;
}

.badge.lan {
  background: #dcfce7;
  color: #15803d;
}

.chips {
  padding: 12px;
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
}

em {
  color: var(--muted);
}

.error {
  color: var(--danger);
}

@media (max-width: 860px) {
  .layout-grid {
    grid-template-columns: 1fr;
  }
}
</style>
