<script setup lang="ts">
import { onMounted, ref } from 'vue'
import JsonBlock from '@/components/common/JsonBlock.vue'
import { networkApi } from '@/api/network'

const loading = ref(false)
const error = ref('')
const summary = ref<Record<string, unknown>>({})
const interfaces = ref<Record<string, unknown>>({})
const bridge = ref<Record<string, unknown>>({})

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
    <div class="grid">
      <JsonBlock title="网络状态 /network" :data="summary" />
      <JsonBlock title="接口列表 /network/interfaces" :data="interfaces" />
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

.error {
  color: var(--danger);
}
</style>
