<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { getPolicyGroups, selectPolicy } from '../api'

const groups = ref<Record<string, unknown>[]>([])
const msg = ref('')

async function load() {
  groups.value = await getPolicyGroups()
}

async function pick(g: Record<string, unknown>, outbound: string) {
  await selectPolicy(String(g.id), outbound)
  msg.value = `已选择 ${outbound}`
  await load()
}

onMounted(load)
</script>

<template>
  <h1 class="page-title">策略组</h1>
  <div v-if="msg" class="msg">{{ msg }}</div>
  <div class="card" v-for="g in groups" :key="String(g.id)">
    <strong>{{ g.name }}</strong> <span class="badge">{{ g.type }}</span>
    <div style="margin-top: .75rem; display: flex; gap: .5rem; flex-wrap: wrap">
      <button
        v-for="ob in (g.outbounds as string[])"
        :key="ob"
        class="btn secondary"
        :class="{ btn: g.selected === ob }"
        @click="pick(g, ob)"
      >
        {{ ob }}{{ g.selected === ob ? ' ✓' : '' }}
      </button>
    </div>
  </div>
</template>
