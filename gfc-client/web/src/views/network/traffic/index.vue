<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref } from 'vue'
import { networkApi } from '@/api/network'

type Sample = {
  ts: string
  bytes_in: number
  bytes_out: number
  rate_in_bps: number
  rate_out_bps: number
}

const ranges = [
  { label: '1 小时', hours: 1 },
  { label: '6 小时', hours: 6 },
  { label: '12 小时', hours: 12 },
  { label: '24 小时', hours: 24 },
  { label: '48 小时', hours: 48 },
]

const hours = ref(24)
const iface = ref('gfctun')
const ifaces = ref<string[]>(['gfctun'])
const loading = ref(false)
const error = ref('')
const samples = ref<Sample[]>([])
const summary = ref<Record<string, number>>({})
let timer: number | undefined

const chart = computed(() => {
  const w = 920
  const h = 260
  const pad = { top: 18, right: 16, bottom: 32, left: 58 }
  const innerW = w - pad.left - pad.right
  const innerH = h - pad.top - pad.bottom
  if (samples.value.length === 0) {
    return { w, h, pad, innerW, innerH, max: 1, inbound: '', outbound: '', coords: [] as Array<{ x: number; yIn: number; yOut: number; s: Sample }> }
  }
  const max = Math.max(
    ...samples.value.map((s) => Math.max(s.rate_in_bps, s.rate_out_bps)),
    1
  )
  const coords = samples.value.map((s, i) => {
    const x = pad.left + (samples.value.length === 1 ? innerW / 2 : (i / (samples.value.length - 1)) * innerW)
    const yIn = pad.top + innerH - (s.rate_in_bps / max) * innerH
    const yOut = pad.top + innerH - (s.rate_out_bps / max) * innerH
    return { x, yIn, yOut, s }
  })
  return {
    w,
    h,
    pad,
    innerW,
    innerH,
    max,
    inbound: coords.map((c) => `${c.x},${c.yIn}`).join(' '),
    outbound: coords.map((c) => `${c.x},${c.yOut}`).join(' '),
    coords,
  }
})

const hover = ref<number | null>(null)

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

async function load() {
  loading.value = true
  error.value = ''
  try {
    await loadInterfaces()
    const res = await networkApi.trafficHistory(hours.value, iface.value)
    if (!res.ok) throw new Error('加载失败')
    const data = res.data as Record<string, unknown>
    samples.value = (data.samples as Sample[]) || []
    summary.value = (data.summary as Record<string, number>) || {}
  } catch (err) {
    error.value = String(err)
  } finally {
    loading.value = false
  }
}

onMounted(() => {
  void load()
  timer = window.setInterval(() => void load(), 60000)
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
        <p>本地 SQLite 每分钟采样多接口流量，最长保留 48 小时。</p>
      </div>
      <button :disabled="loading" @click="load">{{ loading ? '刷新中...' : '刷新' }}</button>
    </header>

    <div class="toolbar">
      <div class="range-group">
        <button
          v-for="item in ranges"
          :key="item.hours"
          :class="{ active: hours === item.hours }"
          @click="hours = item.hours; load()"
        >
          {{ item.label }}
        </button>
      </div>
      <div class="iface-group">
        <span class="iface-label">接口</span>
        <button
          v-for="name in ifaces"
          :key="name"
          :class="{ active: iface === name }"
          @click="iface = name; load()"
        >
          {{ name }}
        </button>
      </div>
    </div>

    <div v-if="error" class="error">{{ error }}</div>

    <div class="summary">
      <div>总入站 {{ formatBytes(summary.total_in || 0) }}</div>
      <div>总出站 {{ formatBytes(summary.total_out || 0) }}</div>
      <div>峰值入站 {{ formatBps(summary.peak_in_bps || 0) }}</div>
      <div>峰值出站 {{ formatBps(summary.peak_out_bps || 0) }}</div>
    </div>

    <div class="panel">
      <svg
        :viewBox="`0 0 ${chart.w} ${chart.h}`"
        width="100%"
        :height="chart.h"
        @mouseleave="hover = null"
      >
        <line
          :x1="chart.pad.left"
          :x2="chart.w - chart.pad.right"
          :y1="chart.pad.top + chart.innerH"
          :y2="chart.pad.top + chart.innerH"
          stroke="#cbd5e1"
        />
        <polyline fill="none" stroke="#3b82f6" stroke-width="2" :points="chart.inbound" />
        <polyline fill="none" stroke="#22c55e" stroke-width="2" :points="chart.outbound" />
        <circle
          v-for="(c, i) in chart.coords"
          :key="c.s.ts"
          :cx="c.x"
          :cy="c.yIn"
          r="3"
          fill="#3b82f6"
          @mouseenter="hover = i"
        />
      </svg>
      <div class="legend">
        <span class="in">入站</span>
        <span class="out">出站</span>
        <span class="hint">每 1 分钟采样，自动保留 48 小时</span>
      </div>
      <div v-if="hover != null && chart.coords[hover]" class="tooltip">
        {{ chart.coords[hover].s.ts }}
        · 入站 {{ formatBps(chart.coords[hover].s.rate_in_bps) }}
        · 出站 {{ formatBps(chart.coords[hover].s.rate_out_bps) }}
      </div>
      <div v-else-if="samples.length === 0" class="empty">暂无历史数据，运行约 1 分钟后出现首个采样点。</div>
    </div>
  </section>
</template>

<style scoped>
.page { display: grid; gap: 14px; }
.page-head, .toolbar, .summary { display: flex; justify-content: space-between; gap: 12px; align-items: center; flex-wrap: wrap; }
.range-group, .iface-group { display: flex; gap: 8px; flex-wrap: wrap; align-items: center; }
.range-group button, .iface-group button, .page-head button {
  border: 1px solid #cbd5e1; background: #fff; border-radius: 8px; padding: 6px 12px; cursor: pointer;
}
.range-group button.active, .iface-group button.active { background: #2563eb; color: #fff; border-color: #2563eb; }
.iface-label { font-weight: 600; color: #334155; }
.summary { color: #475569; font-size: 13px; gap: 18px; }
.panel { background: #fff; border: 1px solid #e2e8f0; border-radius: 12px; padding: 16px; }
.legend { display: flex; gap: 16px; margin-top: 8px; font-size: 13px; }
.legend .in { color: #2563eb; }
.legend .out { color: #16a34a; }
.legend .hint { color: #94a3b8; margin-left: auto; }
.tooltip, .empty, .error { font-size: 13px; margin-top: 8px; color: #334155; }
.error { color: #b91c1c; }
</style>
