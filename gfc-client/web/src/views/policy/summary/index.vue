<script setup lang="ts">
import { onMounted, ref } from 'vue'
import JsonBlock from '@/components/common/JsonBlock.vue'
import { policyApi } from '@/api/policy'

const loading = ref(false)
const actionLoading = ref(false)
const error = ref('')
const message = ref('')
const groups = ref<Record<string, unknown>>({})
const dnsLists = ref<Record<string, unknown>>({})
const rules = ref<Record<string, unknown>>({})
const routing = ref<Record<string, unknown>>({})

async function load() {
  loading.value = true
  error.value = ''
  try {
    const [groupsRes, dnsRes, rulesRes, routingRes] = await Promise.all([
      policyApi.groups(),
      policyApi.dnsLists(),
      policyApi.rules(),
      policyApi.routing(),
    ])
    if (groupsRes.ok) groups.value = groupsRes.data
    if (dnsRes.ok) dnsLists.value = dnsRes.data
    if (rulesRes.ok) rules.value = rulesRes.data
    if (routingRes.ok) routing.value = routingRes.data
  } catch (err) {
    error.value = String(err)
  } finally {
    loading.value = false
  }
}

async function updateRules() {
  actionLoading.value = true
  message.value = ''
  try {
    const res = await policyApi.updateRules()
    message.value = res.ok ? '规则集更新完成' : (res.error?.message ?? '规则集更新失败')
    await load()
  } catch (err) {
    message.value = String(err)
  } finally {
    actionLoading.value = false
  }
}

onMounted(load)
</script>

<template>
  <section class="page">
    <header class="page-head">
      <div>
        <h2>策略总览</h2>
        <p>聚合 DNS 分流、策略组、Geo 规则与路由模式。</p>
      </div>
      <div class="actions">
        <button :disabled="loading" @click="load">{{ loading ? '刷新中...' : '刷新' }}</button>
        <button :disabled="actionLoading" @click="updateRules">{{ actionLoading ? '更新中...' : '更新规则集' }}</button>
      </div>
    </header>
    <div v-if="error" class="error">{{ error }}</div>
    <div v-if="message" class="message">{{ message }}</div>
    <div class="grid">
      <JsonBlock title="代理策略组 /policy/groups" :data="groups" />
      <JsonBlock title="DNS 列表 /dns/lists" :data="dnsLists" />
      <JsonBlock title="规则集 /rules" :data="rules" />
      <JsonBlock title="路由模式 /routing" :data="routing" />
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

.actions {
  display: flex;
  gap: 8px;
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

.message {
  color: var(--ok);
}
</style>
