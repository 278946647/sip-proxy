<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref } from 'vue'
import StatCard from '@/components/common/StatCard.vue'
import { maintenanceApi } from '@/api/maintenance'
import { textValue } from '@/utils/data'

type Artifact = {
  id: number
  version: string
  arch: string
  filename: string
  notes?: string
}

type Progress = {
  phase?: string
  percent?: number
  message?: string
  last_result?: string
  busy?: boolean
}

const loading = ref(false)
const checking = ref(false)
const applying = ref(false)
const error = ref('')
const current = ref('-')
const latest = ref('-')
const updateAvailable = ref(false)
const artifacts = ref<Artifact[]>([])
const selectedId = ref<number | undefined>()
const localPath = ref('')
const progress = ref<Progress>({})
const lastResult = ref('')
const fileInput = ref<HTMLInputElement | null>(null)
let pollTimer: number | undefined

const statusText = computed(() => {
  const p = progress.value
  const phase = p.phase || 'idle'
  const map: Record<string, string> = {
    idle: '空闲',
    checking: '检查中',
    downloading: '下载中',
    extracting: '解压中',
    installing: '安装中',
    done: '完成',
    failed: '失败',
  }
  const label = map[phase] || phase
  return p.message ? `${label} — ${p.message}` : label
})

const percent = computed(() => Number(progress.value.percent || 0))

function applyStatus(d: Record<string, unknown>) {
  current.value = String(d.current || '-')
  latest.value = String(d.platform_latest || d.latest || '-')
  updateAvailable.value = Boolean(d.update_available)
  const p = (d.progress as Progress) || {
    phase: d.phase as string,
    percent: d.percent as number,
    message: d.status_text as string,
    last_result: d.last_result as string,
    busy: d.busy as boolean,
  }
  progress.value = p
  if (p.last_result) lastResult.value = String(p.last_result)
  if (Array.isArray(d.artifacts)) {
    artifacts.value = d.artifacts as Artifact[]
    if (!selectedId.value && artifacts.value.length) selectedId.value = artifacts.value[0].id
  }
}

async function load() {
  loading.value = true
  error.value = ''
  try {
    const res = await maintenanceApi.upgradeStatus()
    if (res.ok) applyStatus(res.data as Record<string, unknown>)
  } catch (err) {
    error.value = String(err)
  } finally {
    loading.value = false
  }
}

async function loadArtifacts() {
  try {
    const res = await fetch('/api/v1/upgrade/artifacts')
    const body = await res.json()
    if (!res.ok) throw new Error(body?.error || body?.message || res.statusText)
    const data = body.data || body
    artifacts.value = data.artifacts || []
    if (!selectedId.value && artifacts.value.length) selectedId.value = artifacts.value[0].id
    if (data.current) current.value = String(data.current)
  } catch (err) {
    /* not activated yet — ignore */
  }
}

function stopPoll() {
  if (pollTimer) {
    window.clearInterval(pollTimer)
    pollTimer = undefined
  }
}

function startPoll() {
  stopPoll()
  pollTimer = window.setInterval(() => {
    void load().then(() => {
      if (!progress.value.busy) {
        stopPoll()
        applying.value = false
      }
    })
  }, 1500)
}

async function check() {
  checking.value = true
  error.value = ''
  try {
    const res = await maintenanceApi.upgradeCheck('')
    if (res.ok) applyStatus(res.data as Record<string, unknown>)
  } catch (err) {
    error.value = String(err)
  } finally {
    checking.value = false
  }
}

async function applyRemote() {
  if (!selectedId.value) {
    error.value = '请先检查更新并选择版本'
    return
  }
  applying.value = true
  error.value = ''
  try {
    const res = await fetch('/api/v1/upgrade/apply-remote', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ artifact_id: selectedId.value }),
    })
    const body = await res.json()
    if (!res.ok) throw new Error(body?.error || body?.message || res.statusText)
    applyStatus({ ...(body.data || body), progress: body.data?.progress || body.progress })
    startPoll()
  } catch (err) {
    error.value = String(err)
    applying.value = false
  }
}

async function applyLocalPath() {
  if (!localPath.value.trim()) {
    error.value = '请填写本地包路径'
    return
  }
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
    startPoll()
  } catch (err) {
    error.value = String(err)
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
    startPoll()
  } catch (err) {
    error.value = String(err)
    applying.value = false
  } finally {
    input.value = ''
  }
}

onMounted(() => {
  void load().then(loadArtifacts)
})
onUnmounted(stopPoll)
</script>

<template>
  <section class="page">
    <header class="page-head">
      <div>
        <h2>系统版本升级</h2>
        <p>从控制平台拉取 runtime；也可上传本地包（线下拷贝场景）。</p>
      </div>
      <button :disabled="loading" @click="load">刷新</button>
    </header>

    <div class="cards">
      <StatCard label="当前版本" :value="textValue(current)" />
      <StatCard label="平台最新" :value="textValue(latest)" />
      <StatCard label="升级状态" :value="statusText" />
    </div>

    <div class="card">
      <h3>从控制平台升级</h3>
      <label>
        可用版本
        <select v-model.number="selectedId">
          <option disabled :value="undefined">请先检查更新</option>
          <option v-for="a in artifacts" :key="a.id" :value="a.id">
            {{ a.version }} / {{ a.arch }} (#{{ a.id }}){{ a.notes ? ` — ${a.notes}` : '' }}
          </option>
        </select>
      </label>
      <div class="row">
        <button :disabled="checking || applying" @click="check">
          {{ checking ? '检查中...' : '检查更新' }}
        </button>
        <button class="primary" :disabled="applying || !selectedId" @click="applyRemote">
          {{ applying ? '升级中...' : '立即升级' }}
        </button>
      </div>
      <div class="bar"><div class="bar-fill" :style="{ width: percent + '%' }" /></div>
      <p class="hint">{{ statusText }} · {{ percent }}%</p>
      <pre v-if="lastResult" class="result">{{ lastResult }}</pre>
      <p v-if="updateAvailable" class="ok">检测到可升级版本</p>
    </div>

    <div class="card">
      <h3>本地包升级（高级）</h3>
      <p class="hint">选择 .tar.gz 上传到本机后安装；等同于 scp + install.sh。</p>
      <label class="file">
        选择文件
        <input ref="fileInput" type="file" accept=".gz,.tgz,.tar.gz" @change="onFileChange" />
      </label>
      <label>
        或设备本地路径
        <input v-model="localPath" placeholder="/tmp/gfc-runtime-xxx.tar.gz" />
      </label>
      <button :disabled="applying || !localPath" @click="applyLocalPath">
        {{ applying ? '安装中...' : '安装本地路径包' }}
      </button>
      <div class="bar"><div class="bar-fill local" :style="{ width: percent + '%' }" /></div>
      <p v-if="error" class="error">{{ error }}</p>
    </div>
  </section>
</template>

<style scoped>
.page{display:grid;gap:14px}
.page-head{display:flex;justify-content:space-between;gap:12px;align-items:center}
h2,h3,p{margin:0}
p{margin-top:4px;color:var(--muted)}
.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));gap:10px}
.card{display:grid;gap:10px;background:var(--panel);border:1px solid var(--border);border-radius:10px;padding:14px;max-width:720px}
label{display:grid;gap:6px;color:var(--muted)}
input,select{border:1px solid var(--border);border-radius:8px;padding:7px}
.row{display:flex;gap:8px;flex-wrap:wrap}
button{border:0;border-radius:8px;padding:8px 12px;color:#fff;background:#64748b;cursor:pointer}
button.primary,button:not(:disabled){background:var(--brand)}
button:disabled{opacity:.6;cursor:not-allowed}
.bar{height:12px;background:#e5e7eb;border-radius:999px;overflow:hidden}
.bar-fill{height:100%;background:var(--brand);transition:width .2s}
.bar-fill.local{background:#16a34a}
.hint{font-size:13px}
.result{white-space:pre-wrap;background:#0f172a08;padding:10px;border-radius:8px;max-height:220px;overflow:auto;font-size:12px}
.error{color:var(--danger)}.ok{color:#16a34a}.file{margin-top:4px}
</style>
