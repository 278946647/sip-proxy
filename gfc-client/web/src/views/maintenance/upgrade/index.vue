<script setup lang="ts">
import { onMounted, ref } from 'vue'
import JsonBlock from '@/components/common/JsonBlock.vue'
import StatCard from '@/components/common/StatCard.vue'
import { maintenanceApi } from '@/api/maintenance'
import { textValue } from '@/utils/data'

const loading = ref(false)
const checking = ref(false)
const manifestUrl = ref('')
const error = ref('')
const upgrade = ref<Record<string, unknown>>({})

async function load() {
  loading.value = true
  error.value = ''
  try {
    const res = await maintenanceApi.upgradeStatus()
    if (res.ok) upgrade.value = res.data
  } catch (err) {
    error.value = String(err)
  } finally {
    loading.value = false
  }
}

async function check() {
  checking.value = true
  error.value = ''
  try {
    const res = await maintenanceApi.upgradeCheck(manifestUrl.value)
    if (res.ok) upgrade.value = res.data
  } catch (err) {
    error.value = String(err)
  } finally {
    checking.value = false
  }
}

onMounted(load)
</script>

<template>
  <section class="page">
    <header class="page-head">
      <div><h2>系统升级</h2><p>查看当前版本与远端 manifest 检查结果。</p></div>
      <button :disabled="loading" @click="load">刷新</button>
    </header>
    <div class="cards">
      <StatCard label="当前版本" :value="textValue(upgrade.current || upgrade.version)" />
      <StatCard label="最新版本" :value="textValue(upgrade.latest || upgrade.remote_version)" />
      <StatCard label="是否可升级" :value="textValue(upgrade.update_available || upgrade.upgradable)" />
    </div>
    <div class="card">
      <label>Manifest URL<input v-model="manifestUrl" placeholder="留空使用默认 manifest" /></label>
      <button :disabled="checking" @click="check">{{ checking ? '检查中...' : '检查更新' }}</button>
      <p v-if="error" class="error">{{ error }}</p>
    </div>
    <JsonBlock title="升级原始响应" :data="upgrade" />
  </section>
</template>

<style scoped>
.page{display:grid;gap:14px}.page-head{display:flex;justify-content:space-between;gap:12px;align-items:center}h2,p{margin:0}p{margin-top:4px;color:var(--muted)}.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));gap:10px}.card{display:grid;gap:10px;background:var(--panel);border:1px solid var(--border);border-radius:10px;padding:12px;max-width:680px}label{display:grid;gap:6px;color:var(--muted)}input{border:1px solid var(--border);border-radius:8px;padding:7px}button{border:0;border-radius:8px;padding:8px 12px;color:#fff;background:var(--brand);cursor:pointer}.error{color:var(--danger)}
</style>
