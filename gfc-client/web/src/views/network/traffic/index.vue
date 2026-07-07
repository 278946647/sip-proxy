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

const timeRanges = [
  { label: '1 小时', hours: 1 },
  { label: '6 小时', hours: 6 },
  { label: '12 小时', hours: 12 },
  { label: '24 小时', hours: 24 },
  { label: '48 小时', hours: 48 },
]

const hours = ref(1)
const iface = ref('gfctun')
const ifaces = ref<string[]>(['gfctun'])
const samples = ref<Sample[]>([])
const summary = ref<Record<string, number>>({})
const loading = ref(false)
const error = ref('')
const canvasRef = ref<HTMLCanvasElement | null>(null)
let timer: number | undefined

function formatBps(v: number) {
  if (v < 1000) return `${Math.round(v)} bit/s`
  if (v < 1000 * 1000) return `${(v / 1000).toFixed(2)} Kibit/s`
  return `${(v / 1000 / 1000).toFixed(2)} Mbit/s`
}

function formatBytes(n: number) {
  if (n < 1024) return `${n} B`
  if (n < 1024 ** 2) return `${(n / 1024).toFixed(1)} KB`
  if (n < 1024 ** 3) return `${(n / 1024 ** 2).toFixed(1)} MB`
  return `${(n / 1024 ** 3).toFixed(2)} GB`
}

function niceMax(v: number) {
  if (v <= 0) return 1000
  const exp = 10 ** Math.floor(Math.log10(v))
  const f = v / exp
  const nice = f <= 1 ? 1 : f <= 2 ? 2 : f <= 5 ? 5 : 10
  return nice * exp
}

function drawChart() {
  const canvas = canvasRef.value
  if (!canvas) return
  const parent = canvas.parentElement
  const w = parent?.clientWidth ? Math.max(parent.clientWidth, 320) : 900
  const h = 280
  const dpr = window.devicePixelRatio || 1
  canvas.width = Math.floor(w * dpr)
  canvas.height = Math.floor(h * dpr)
  canvas.style.width = `${w}px`
  canvas.style.height = `${h}px`
  const ctx = canvas.getContext('2d')
  if (!ctx) return
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
  ctx.clearRect(0, 0, w, h)
  ctx.fillStyle = '#fff'
  ctx.fillRect(0, 0, w, h)
  const pad = { top: 22, right: 18, bottom: 40, left: 78 }
  const innerW = w - pad.left - pad.right
  const innerH = h - pad.top - pad.bottom
  const baseY = pad.top + innerH
  const data = samples.value
  if (!data.length) return
  let max = niceMax(Math.max(...data.map((s) => Math.max(s.rate_in_bps, s.rate_out_bps)), 1))
  const gridLines = 4
  ctx.strokeStyle = '#e8e8e8'
  ctx.fillStyle = '#666'
  ctx.font = '11px sans-serif'
  for (let g = 0; g <= gridLines; g++) {
    const y = pad.top + (innerH / gridLines) * g
    const val = max * (1 - g / gridLines)
    ctx.beginPath()
    ctx.moveTo(pad.left, y)
    ctx.lineTo(w - pad.right, y)
    ctx.stroke()
    ctx.fillText(formatBps(val), 6, y + 4)
  }
  const xAt = (i: number) => pad.left + (data.length === 1 ? innerW / 2 : (i / (data.length - 1)) * innerW)
  const yAt = (v: number) => pad.top + innerH - (v / max) * innerH
  const fillArea = (color: string, key: 'rate_in_bps' | 'rate_out_bps') => {
    ctx.beginPath()
    ctx.moveTo(xAt(0), baseY)
    data.forEach((s, i) => ctx.lineTo(xAt(i), yAt(s[key])))
    ctx.lineTo(xAt(data.length - 1), baseY)
    ctx.closePath()
    ctx.fillStyle = color
    ctx.fill()
  }
  const strokeLine = (color: string, key: 'rate_in_bps' | 'rate_out_bps') => {
    ctx.beginPath()
    data.forEach((s, i) => {
      const x = xAt(i)
      const y = yAt(s[key])
      if (i === 0) ctx.moveTo(x, y)
      else ctx.lineTo(x, y)
    })
    ctx.strokeStyle = color
    ctx.lineWidth = 1.5
    ctx.stroke()
  }
  fillArea('rgba(0, 84, 166, 0.22)', 'rate_in_bps')
  strokeLine('#0054a6', 'rate_in_bps')
  fillArea('rgba(0, 177, 33, 0.30)', 'rate_out_bps')
  strokeLine('#00b121', 'rate_out_bps')
}

async function loadInterfaces() {
  const res = await networkApi.trafficInterfaces()
  if (!res.ok) return
  const data = res.data as Record<string, unknown>
  const list = (data.interfaces as string[]) || []
  if (list.length) {
    ifaces.value = list
    if (!list.includes(iface.value)) iface.value = String(data.default || list[0])
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
    requestAnimationFrame(drawChart)
  } catch (err) {
    error.value = String(err)
  } finally {
    loading.value = false
  }
}

onMounted(() => {
  void load()
  timer = window.setInterval(() => void load(), 60000)
  window.addEventListener('resize', drawChart)
})
onUnmounted(() => {
  if (timer) window.clearInterval(timer)
  window.removeEventListener('resize', drawChart)
})
</script>

<template>
  <section class="page">
    <header class="page-head">
      <div>
        <h2>接口流量</h2>
        <p>默认 1 小时，点击时段标签加载对应区间流量图。</p>
      </div>
      <button :disabled="loading" @click="load">{{ loading ? '刷新中...' : '刷新' }}</button>
    </header>

    <div class="tabs">
      <button
        v-for="name in ifaces"
        :key="name"
        :class="{ active: iface === name }"
        @click="iface = name; load()"
      >
        {{ name }}
      </button>
    </div>

    <div class="tabs range">
      <button
        v-for="item in timeRanges"
        :key="item.hours"
        :class="{ active: hours === item.hours }"
        @click="hours = item.hours; load()"
      >
        {{ item.label }}
      </button>
    </div>

    <div v-if="error" class="error">{{ error }}</div>

    <div class="summary">
      <div>总入站 {{ formatBytes(summary.total_in || 0) }}</div>
      <div>总出站 {{ formatBytes(summary.total_out || 0) }}</div>
      <div>峰值入站 {{ formatBps(summary.peak_in_bps || 0) }}</div>
      <div>峰值出站 {{ formatBps(summary.peak_out_bps || 0) }}</div>
    </div>

    <div class="panel">
      <canvas ref="canvasRef" />
      <div class="legend">
        <span class="in">入站</span>
        <span class="out">出站</span>
        <span class="hint">{{ samples.length ? `最近 ${hours} 小时 · ${samples.length} 个采样点` : '暂无数据' }}</span>
      </div>
    </div>
  </section>
</template>

<style scoped>
.page { display: grid; gap: 14px; }
.page-head { display: flex; justify-content: space-between; gap: 12px; align-items: center; flex-wrap: wrap; }
.tabs { display: flex; gap: 0; flex-wrap: wrap; border-bottom: 1px solid #e0e0e0; }
.tabs button {
  border: 1px solid #e0e0e0; border-bottom: none; background: #f8f8f8; padding: 8px 14px; cursor: pointer; margin-right: -1px;
}
.tabs button.active { background: #fff; color: #0069d6; font-weight: 600; border-bottom: 1px solid #fff; margin-bottom: -1px; }
.tabs.range { border-bottom: none; margin-top: 4px; }
.summary { color: #475569; font-size: 13px; display: flex; gap: 18px; flex-wrap: wrap; }
.panel { background: #fff; border: 1px solid #e2e8f0; border-radius: 8px; padding: 12px; }
canvas { width: 100%; height: 280px; display: block; border: 1px solid #e0e0e0; border-radius: 2px; }
.legend { display: flex; gap: 16px; margin-top: 8px; font-size: 13px; }
.legend .in { color: #0054a6; }
.legend .out { color: #00b121; }
.legend .hint { color: #94a3b8; margin-left: auto; }
.error { color: #b91c1c; font-size: 13px; }
.page-head button { border: 1px solid #cbd5e1; background: #fff; border-radius: 8px; padding: 6px 12px; cursor: pointer; }
</style>
