<script setup lang="ts">
import { ref } from 'vue'
import JsonBlock from '@/components/common/JsonBlock.vue'
import { maintenanceApi } from '@/api/maintenance'

const loading = ref('')
const result = ref<Record<string, unknown>>({})
const message = ref('')

async function run(action: 'reload' | 'apply' | 'rollback') {
  if (action === 'rollback' && !confirm('确认回滚数据面配置？')) return
  loading.value = action
  message.value = ''
  try {
    const api = action === 'reload' ? maintenanceApi.dataplaneReload : action === 'apply' ? maintenanceApi.dataplaneApply : maintenanceApi.dataplaneRollback
    const res = await api()
    result.value = res.data || {}
    message.value = res.ok ? `${action} 完成` : (res.error?.message ?? `${action} 失败`)
  } catch (err) {
    message.value = String(err)
  } finally {
    loading.value = ''
  }
}
</script>

<template>
  <section class="page">
    <header class="page-head">
      <div><h2>配置应用 / 回滚</h2><p>对 Unbound、Sing-box、nftables 等数据面执行应用、重载和回滚。</p></div>
    </header>
    <div class="card">
      <button :disabled="!!loading" @click="run('reload')">重载当前配置</button>
      <button :disabled="!!loading" @click="run('apply')">应用下发配置</button>
      <button class="danger" :disabled="!!loading" @click="run('rollback')">回滚上次配置</button>
      <p v-if="message" class="message">{{ message }}</p>
    </div>
    <JsonBlock title="最近一次操作结果" :data="result" />
  </section>
</template>

<style scoped>
.page{display:grid;gap:14px}.page-head{display:flex;justify-content:space-between;gap:12px;align-items:center}h2,p{margin:0}p{margin-top:4px;color:var(--muted)}.card{display:flex;flex-wrap:wrap;gap:10px;align-items:center;background:var(--panel);border:1px solid var(--border);border-radius:10px;padding:12px}button{border:0;border-radius:8px;padding:8px 12px;color:#fff;background:var(--brand);cursor:pointer}.danger{background:var(--danger)}.message{width:100%;color:var(--ok)}
</style>
