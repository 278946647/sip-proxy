<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { getDNSLists, updateDNS, easyMosdnsUpdate } from '../api'

const lists = ref<Record<string, unknown>>({})
const domains = ref('')
const listName = ref('china')
const msg = ref('')

async function load() {
  lists.value = (await getDNSLists()).lists as Record<string, unknown>
}

async function append() {
  const lines = domains.value.split('\n').map((s) => s.trim()).filter(Boolean)
  await updateDNS(listName.value, lines, 'append')
  msg.value = `已追加 ${lines.length} 条到 ${listName.value}`
  domains.value = ''
  await load()
}

async function updateEasy() {
  const r = await easyMosdnsUpdate()
  msg.value = String(r.message || '已更新')
}

onMounted(load)
</script>

<template>
  <h1 class="page-title">DNS 列表</h1>
  <div v-if="msg" class="msg">{{ msg }}</div>
  <div class="grid">
    <div class="card" v-for="(info, key) in lists" :key="String(key)">
      <div class="stat-label">{{ key }}</div>
      <div class="stat-value">{{ (info as any).count }}</div>
    </div>
  </div>
  <div class="card">
    <label>列表</label>
    <select v-model="listName" style="margin: .5rem 0">
      <option value="block">block</option>
      <option value="china">china</option>
      <option value="global">global</option>
    </select>
    <textarea v-model="domains" rows="6" placeholder="每行一个域名" />
    <button class="btn" style="margin-top: .75rem" @click="append">追加域名</button>
    <button class="btn secondary" style="margin-top: .75rem; margin-left: .5rem" @click="updateEasy">
      更新 EasyMosDNS
    </button>
  </div>
</template>
