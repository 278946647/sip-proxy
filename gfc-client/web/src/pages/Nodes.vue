<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { getNodes } from '../api'

const nodes = ref<Record<string, unknown>[]>([])
onMounted(async () => { nodes.value = await getNodes() })
</script>

<template>
  <h1 class="page-title">节点</h1>
  <div class="card" v-for="n in nodes" :key="String(n.id)">
    <strong>{{ n.name }}</strong>
    <div style="color: var(--muted); margin-top: .35rem">
      {{ n.server }}:{{ n.port }} · {{ n.type || 'vless' }}
    </div>
  </div>
  <div v-if="!nodes.length" class="card">暂无节点，请先刷码激活</div>
</template>
