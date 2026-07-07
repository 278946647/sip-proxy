<script setup lang="ts">
import { onMounted, onUnmounted, ref } from 'vue'
import { networkApi } from '@/api/network'

type Sample = {
  ts: string
  bytes_in: number
  bytes_out: number
  rate_in_bps: number
  rate_out_bps: number
}

type HistoryBlock = {
  hours: number
  title: string
  samples: Sample[]
  summary: Record<string, number>
}

const optionalRanges = [
  { label: '6 小时', hours: 6 },
  { label: '12 小时', hours: 12 },
  { label: '24 小时', hours: 24 },
  { label: '48 小时', hours: 48 },
]

const iface = ref('gfctun')
const ifaces = ref<string[]>(['gfctun'])
const enabled = ref<Record<number, boolean>>({ 6: false, 12: false, 24: false, 48: false })
const blocks = ref<HistoryBlock[]>([])
const loading = ref(false)
const error = ref('')
let timer: number | undefined

function formatBps(v: number) {
  if (v < 1000) return `${Math.round(v)} bit/s`
  if (v < 1000 * 1000) return `${(v / 1000).toFixed(1)} Kibit/s`
  return `${(v / 1000 / 1000).toFixed(2)} Mbit/s`
}

function formatBytes(n: number) {
  if (n < 1024) return `${n} B`
  if (n < 1024 ** 2) return `${(n / 1024).toFixed(1)} KB`
  if (n < 1024 ** 3) return `${(n / 1024 ** 2).toFixed(1)} MB`
  return `${(n / 1024 ** 3).toFixed(2)} GB`
}

function chartPoints(samples: Sample[]) {
  const w = 920
  const h = 220
  const pad = { top: 16, right: 16, bottom: 28, left: 56 }
  const innerW = w - pad.left - pad.right
  const innerH = h - pad.top - pad.bottom
  if (!samples.length) {
    return { w, h, pad, innerH, inbound: '', outbound: '' }
  }
  const max = Math.max(...samples.map((s) => Math.max(s.rate_in_bps, s.rate_out_bps)), 1)
  const coords = samples.map((s, i) => {
    const x = pad.left + (samples.length === 1 ? innerW / 2 : (i / (samples.length - 1)) * innerW)
    const yIn = pad.top + innerH - (s.rate_in_bps / max) * innerH
    const yOut = pad.top + innerH - (s.rate_out_bps / max) * innerH
    return { x, yIn, yOut }
  })
  return {
    w,
    h,
    pad,
    innerH,
    inbound: coords.map((c) => `${c.x},${c.yIn}`).join(' '),
    outbound: coords.map((c) => `${c.x},${c.yOut}`).join(' '),
  }
}

async function fetchHistory(hours: number) {
  const res = await networkApi.trafficHistory(hours, iface.value)
  if (!res.ok) throw new Error('加载失败')
  const data = res.data as Record<string, unknown>
  return {
    hours,
    title: hours === 1 ? '最近 1 小时（默认）' : `最近 ${hours} 小时`,
    samples: (data.samples as Sample[]) || [],
    summary: (data.summary as Record<string, number>) || {},
  }
}

async function loadInterfaces() {
  const res = await networkApi.trafficInterfaces()
  if (!res.ok) return
  const data = res.data as Record<string, unknown>
  const list = (data.interfaces as string[]) || []
  if (list.length) {
    ifaces.value = list
    if (!list.includes(iface.value)) {
      iface.value = String(data.default || list[0])
    }
  }
}

async function loadAll() {
  loading.value = true
  error.value = ''
  try {
    await loadInterfaces()
    const next: HistoryBlock[] = [await fetchHistory(1)]
    for (const item of optionalRanges) {
      if (enabled.value[item.hours]) {
        next.push(await fetchHistory(item.hours))
      }
    }
    blocks.value = next
  } catch (err) {
    error.value = String(err)
  } finally {
    loading.value = false
  }
}

async function onToggle(hours: number, checked: boolean) {
  enabled.value[hours] = checked
  if (!checked) {
    blocks.value = blocks.value.filter((b) => b.hours === 1 || b.hours !== hours)
    return
  }
  loading.value = true
  error.value = ''
  try {
    const block = await fetchHistory(hours)
    blocks.value = [...blocks.value.filter((b) => b.hours !== hours), block].sort((a, b) => a.hours - b.hours)
  } catch (err) {
    enabled.value[hours] = false
    error.value = String(err)
  } finally {
    loading.value = false
  }
}

onMounted(() => {
  void loadAll()
  timer = window.setInterval(() => void loadAll(), 60000)
})
onUnmounted(() => {
  if (timer) window.clearInterval(timer)
})
</script>

<template>
  <section class="page">
    <header class="page-head">
      <div>
        <h2>接口流量</h2>
        <p>默认显示最近 1 小时；勾选其他时段后按需加载图表。</p>
      </div>
      <button :disabled="loading" @click="loadAll">{{ loading ? '刷新中...' : '刷新' }}</button>
    </header>

    <div class="toolbar">
      <div class="iface-group">
        <span class="iface-label">接口</span>
        <button
          v-for="name in ifaces"
          :key="name"
          :class="{ active: iface === name }"
          @click="iface = name; loadAll()"
        >
          {{ name }}
        </button>
      </div>
      <div class="check-group">
        <span class="iface-label">附加时段</span>
        <label v-for="item in optionalRanges" :key="item.hours">
          <input
            type="checkbox"
            :checked="enabled[item.hours]"
            @change="onToggle(item.hours, ($event.target as HTMLInputElement).checked)"
          />
          {{ item.label }}
        </label>
      </div>
    </div>

    <div v-if="error" class="error">{{ error }}</div>

    <article v-for="block in blocks" :key="block.hours" class="panel">
      <h3>{{ block.title }}</h3>
      <div class="summary">
        <div>总入站 {{ formatBytes(block.summary.total_in || 0) }}</div>
        <div>总出站 {{ formatBytes(block.summary.total_out || 0) }}</div>
        <div>峰值入站 {{ formatBps(block.summary.peak_in_bps || 0) }}</div>
        <div>峰值出站 {{ formatBps(block.summary.peak_out_bps || 0) }}</div>
      </div>
      <svg
        :viewBox="`0 0 ${chartPoints(block.samples).w} ${chartPoints(block.samples).h}`"
        width="100%"
        :height="chartPoints(block.samples).h"
      >
        <line
          :x1="chartPoints(block.samples).pad.left"
          :x2="chartPoints(block.samples).w - chartPoints(block.samples).pad.right"
          :y1="chartPoints(block.samples).pad.top + chartPoints(block.samples).innerH"
          :y2="chartPoints(block.samples).pad.top + chartPoints(block.samples).innerH"
          stroke="#cbd5e1"
        />
        <polyline fill="none" stroke="#3b82f6" stroke-width="2" :points="chartPoints(block.samples).inbound" />
        <polyline fill="none" stroke="#22c55e" stroke-width="2" :points="chartPoints(block.samples).outbound" />
      </svg>
      <div class="legend">
        <span class="in">入站</span>
        <span class="out">出站</span>
        <span class="hint">{{ block.samples.length ? `共 ${block.samples.length} 个采样点` : '暂无该时段数据' }}</span>
      </div>
    </article>
  </section>
</template>

<style scoped>
.page { display: grid; gap: 14px; }
.page-head, .toolbar, .summary { display: flex; justify-content: space-between; gap: 12px; align-items: center; flex-wrap: wrap; }
.iface-group, .check-group { display: flex; gap: 8px; flex-wrap: wrap; align-items: center; }
.iface-group button, .page-head button {
  border: 1px solid #cbd5e1; background: #fff; border-radius: 8px; padding: 6px 12px; cursor: pointer;
}
.iface-group button.active { background: #2563eb; color: #fff; border-color: #2563eb; }
.check-group label { display: inline-flex; align-items: center; gap: 6px; font-size: 13px; color: #334155; }
.iface-label { font-weight: 600; color: #334155; }
.panel { background: #fff; border: 1px solid #e2e8f0; border-radius: 12px; padding: 16px; display: grid; gap: 10px; }
.panel h3 { margin: 0; font-size: 15px; }
.summary { color: #475569; font-size: 13px; gap: 18px; }
.legend { display: flex; gap: 16px; font-size: 13px; }
.legend .in { color: #2563eb; }
.legend .out { color: #16a34a; }
.legend .hint { color: #94a3b8; margin-left: auto; }
.error { color: #b91c1c; font-size: 13px; }
</style>
