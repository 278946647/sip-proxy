<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import JsonBlock from '@/components/common/JsonBlock.vue'
import { connectivityApi } from '@/api/connectivity'
import { asArray, asRecord, textValue } from '@/utils/data'

const loading = ref(false)
const error = ref('')
const payload = ref<Record<string, unknown>>({})

const nodes = computed(() => asArray(payload.value.nodes).map(asRecord))

async function load() {
  loading.value = true
  error.value = ''
  try {
    const res = await connectivityApi.nodes()
    if (res.ok) payload.value = res.data
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
      <div><h2>节点列表</h2><p>显示控制平台下发或本地 bundle 中的转发节点。</p></div>
      <button :disabled="loading" @click="load">刷新</button>
    </header>
    <p v-if="error" class="error">{{ error }}</p>
    <div class="grid" v-if="nodes.length">
      <div v-for="(node, index) in nodes" :key="`${textValue(node.id || node.name)}-${index}`" class="card">
        <h3>{{ textValue(node.name || node.id || `节点 ${index + 1}`) }}</h3>
        <p>区域：{{ textValue(node.region || node.location) }}</p>
        <p>地址：{{ textValue(node.host || node.ip || node.server) }}</p>
        <p>端口：{{ textValue(node.port || node.listen_port) }}</p>
        <p>状态：{{ textValue(node.status || node.health || node.state) }}</p>
      </div>
    </div>
    <JsonBlock title="节点原始响应 /nodes" :data="payload" />
  </section>
</template>

<style scoped>
.page{display:grid;gap:14px}.page-head{display:flex;justify-content:space-between;gap:12px;align-items:center}h2,h3,p{margin:0}p{margin-top:4px;color:var(--muted)}button{border:0;border-radius:8px;padding:8px 12px;color:#fff;background:var(--brand);cursor:pointer}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:12px}.card{display:grid;gap:5px;background:var(--panel);border:1px solid var(--border);border-radius:10px;padding:12px}.error{color:var(--danger)}
</style>
