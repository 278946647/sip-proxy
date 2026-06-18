<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import DataTable from '@/components/common/DataTable.vue'
import JsonBlock from '@/components/common/JsonBlock.vue'
import { policyApi } from '@/api/policy'
import { asArray, asRecord } from '@/utils/data'

const loading = ref(false)
const error = ref('')
const firewall = ref<Record<string, unknown>>({})
const rows = computed(() => asArray(firewall.value.nftables).map(asRecord))

async function load() {
  loading.value = true
  error.value = ''
  try {
    const res = await policyApi.firewall()
    if (res.ok) firewall.value = res.data
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
      <div><h2>nftables</h2><p>查看设备防火墙配置文件状态。编辑规则后续接入专用策略模型。</p></div>
      <button :disabled="loading" @click="load">刷新</button>
    </header>
    <div v-if="error" class="error">{{ error }}</div>
    <DataTable :columns="[
      { key: 'path', title: '配置文件' },
      { key: 'exists', title: '存在' },
    ]" :rows="rows" />
    <JsonBlock title="防火墙调试数据" :data="firewall" />
  </section>
</template>

<style scoped>
.page{display:grid;gap:12px}.page-head{display:flex;justify-content:space-between;align-items:center;gap:12px}h2,p{margin:0}p{margin-top:4px;color:var(--muted)}button{border:0;border-radius:4px;padding:7px 12px;color:#fff;background:#2563eb;cursor:pointer}.error{color:var(--danger)}
</style>
