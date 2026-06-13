<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { getRules, getRouting, setRouting, updateRules } from '../api'

const rules = ref<Record<string, unknown>[]>([])
const routing = ref<Record<string, unknown>>({})
const msg = ref('')

async function load() {
  rules.value = await getRules()
  routing.value = await getRouting()
}

async function toggleMode() {
  const next = routing.value.mode === 'global' ? 'split' : 'global'
  await setRouting(next)
  msg.value = `routing=${next}`
  await load()
}

async function refresh() {
  const r = await updateRules()
  msg.value = JSON.stringify(r.updated || [])
  await load()
}

onMounted(load)
</script>

<template>
  <h1 class="page-title">分流规则</h1>
  <div v-if="msg" class="msg">{{ msg }}</div>
  <div class="card">
    <div>模式: <strong>{{ routing.mode }}</strong></div>
    <button class="btn secondary" style="margin-top: .75rem" @click="toggleMode">切换 split/global</button>
    <button class="btn" style="margin-top: .75rem; margin-left: .5rem" @click="refresh">更新 meta-rules</button>
  </div>
  <div class="card" v-for="r in rules" :key="String(r.tag)">
    {{ r.tag }} · {{ r.filename }} · {{ r.size || 0 }} bytes
  </div>
</template>
