<script setup lang="ts">
import { onMounted, ref } from 'vue'
import JsonBlock from '@/components/common/JsonBlock.vue'
import StatCard from '@/components/common/StatCard.vue'
import { maintenanceApi } from '@/api/maintenance'
import { textValue } from '@/utils/data'

const loading = ref(false)
const checking = ref(false)
const applying = ref(false)
const manifestUrl = ref('')
const localPath = ref('')
const error = ref('')
const upgrade = ref<Record<string, unknown>>({})
const applyResult = ref<Record<string, unknown>>({})
const fileInput = ref<HTMLInputElement | null>(null)

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

async function applyLocalPath() {
  applying.value = true
  error.value = ''
  try {
    const res = await fetch('/api/v1/upgrade/apply-local', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ path: localPath.value }),
    })
    const body = await res.json()
    if (!res.ok) throw new Error(body?.error || body?.message || res.statusText)
    applyResult.value = body.data || body
    await load()
  } catch (err) {
    error.value = String(err)
  } finally {
    applying.value = false
  }
}

async function onFileChange(ev: Event) {
  const input = ev.target as HTMLInputElement
  const file = input.files?.[0]
  if (!file) return
  applying.value = true
  error.value = ''
  try {
    const fd = new FormData()
    fd.append('file', file)
    const res = await fetch('/api/v1/upgrade/apply-file', { method: 'POST', body: fd })
    const body = await res.json()
    if (!res.ok) throw new Error(body?.error || body?.message || res.statusText)
    applyResult.value = body.data || body
    await load()
  } catch (err) {
    error.value = String(err)
  } finally {
    applying.value = false
    input.value = ''
  }
}

onMounted(load)
</script>

<template>
  <section class="page">
    <header class="page-head">
      <div>
        <h2>系统版本升级</h2>
        <p>控制平台可下发 OTA；此处支持本地包安装（等同 install.sh）。</p>
      </div>
      <button :disabled="loading" @click="load">刷新</button>
    </header>
    <div class="cards">
      <StatCard label="当前版本" :value="textValue(upgrade.current || upgrade.version)" />
      <StatCard label="最新版本" :value="textValue(upgrade.latest || upgrade.remote_version)" />
      <StatCard label="是否可升级" :value="textValue(upgrade.update_available || upgrade.upgradable)" />
    </div>
    <div class="card">
      <h3>检查更新</h3>
      <label>Manifest URL<input v-model="manifestUrl" placeholder="留空使用默认 manifest" /></label>
      <button :disabled="checking" @click="check">{{ checking ? '检查中...' : '检查更新' }}</button>
    </div>
    <div class="card">
      <h3>本地包升级</h3>
      <label>设备本地路径<input v-model="localPath" placeholder="/tmp/gfc-runtime-xxx.tar.gz" /></label>
      <button :disabled="applying || !localPath" @click="applyLocalPath">{{ applying ? '安装中...' : '安装本地路径包' }}</button>
      <label class="file">
        或上传包
        <input ref="fileInput" type="file" accept=".gz,.tgz,.tar.gz" @change="onFileChange" />
      </label>
      <p v-if="error" class="error">{{ error }}</p>
    </div>
    <JsonBlock title="升级状态" :data="upgrade" />
    <JsonBlock title="最近安装结果" :data="applyResult" />
  </section>
</template>

<style scoped>
.page{display:grid;gap:14px}.page-head{display:flex;justify-content:space-between;gap:12px;align-items:center}h2,h3,p{margin:0}p{margin-top:4px;color:var(--muted)}.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));gap:10px}.card{display:grid;gap:10px;background:var(--panel);border:1px solid var(--border);border-radius:10px;padding:12px;max-width:680px}label{display:grid;gap:6px;color:var(--muted)}input{border:1px solid var(--border);border-radius:8px;padding:7px}button{border:0;border-radius:8px;padding:8px 12px;color:#fff;background:var(--brand);cursor:pointer}.error{color:var(--danger)}.file{margin-top:8px}
</style>
