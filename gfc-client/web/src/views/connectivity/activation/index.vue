<script setup lang="ts">
import { onMounted, ref } from 'vue'
import JsonBlock from '@/components/common/JsonBlock.vue'
import { connectivityApi } from '@/api/connectivity'

const loading = ref(false)
const flashing = ref(false)
const clearing = ref(false)
const error = ref('')
const message = ref('')
const code = ref('')
const resetState = ref(false)
const activation = ref<Record<string, unknown>>({})
const nodes = ref<Record<string, unknown>>({})
const agent = ref<Record<string, unknown>>({})

async function load() {
  loading.value = true
  error.value = ''
  try {
    const results = await Promise.allSettled([
      connectivityApi.activation(),
      connectivityApi.nodes(),
      connectivityApi.agent(),
    ])
    const [activationRes, nodesRes, agentRes] = results
    if (activationRes.status === 'fulfilled' && activationRes.value.ok) activation.value = activationRes.value.data
    if (nodesRes.status === 'fulfilled' && nodesRes.value.ok) nodes.value = nodesRes.value.data
    if (agentRes.status === 'fulfilled' && agentRes.value.ok) agent.value = agentRes.value.data
  } catch (err) {
    error.value = String(err)
  } finally {
    loading.value = false
  }
}

async function flash() {
  if (!code.value.trim()) {
    message.value = '请输入线路码'
    return
  }
  flashing.value = true
  message.value = ''
  try {
    const res = await connectivityApi.flashCode(code.value.trim(), resetState.value)
    message.value = res.ok ? '线路码已写入并应用' : (res.error?.message ?? '刷码失败')
    await load()
  } catch (err) {
    message.value = String(err)
  } finally {
    flashing.value = false
  }
}

async function clearActivation() {
  if (!confirm('确认清除当前激活信息？')) return
  clearing.value = true
  message.value = ''
  try {
    const res = await connectivityApi.clearActivation()
    message.value = res.ok ? '激活信息已清除' : (res.error?.message ?? '清除失败')
    await load()
  } catch (err) {
    message.value = String(err)
  } finally {
    clearing.value = false
  }
}

onMounted(load)
</script>

<template>
  <section class="page">
    <header class="page-head">
      <div>
        <h2>线路码 / 激活</h2>
        <p>读取当前激活状态、节点与 Agent 同步信息，并支持重新刷码。</p>
      </div>
      <button :disabled="loading" @click="load">{{ loading ? '刷新中...' : '刷新' }}</button>
    </header>

    <div class="card">
      <h3>刷入线路码</h3>
      <textarea v-model="code" rows="5" placeholder="粘贴控制平台生成的线路码" />
      <label class="check">
        <input v-model="resetState" type="checkbox" />
        重置本地状态后刷入
      </label>
      <div class="actions">
        <button :disabled="flashing" @click="flash">{{ flashing ? '刷码中...' : '刷码并应用' }}</button>
        <button class="danger" :disabled="clearing" @click="clearActivation">{{ clearing ? '清除中...' : '清除激活' }}</button>
      </div>
      <p v-if="message" class="message">{{ message }}</p>
      <p v-if="error" class="error">{{ error }}</p>
    </div>

    <div class="grid">
      <JsonBlock title="激活状态 /activation" :data="activation" />
      <JsonBlock title="节点列表 /nodes" :data="nodes" />
      <JsonBlock title="Agent 状态 /agent" :data="agent" />
    </div>
  </section>
</template>

<style scoped>
.page {
  display: grid;
  gap: 14px;
}

.page-head {
  display: flex;
  justify-content: space-between;
  gap: 12px;
  align-items: center;
}

h2,
h3,
p {
  margin: 0;
}

p {
  margin-top: 4px;
  color: var(--muted);
}

.card {
  background: var(--panel);
  border: 1px solid var(--border);
  border-radius: 10px;
  padding: 14px;
  display: grid;
  gap: 10px;
}

textarea {
  width: 100%;
  resize: vertical;
  border: 1px solid var(--border);
  border-radius: 8px;
  padding: 8px;
}

.check {
  display: flex;
  gap: 6px;
  align-items: center;
  color: var(--muted);
}

.actions {
  display: flex;
  gap: 8px;
}

button {
  border: 0;
  border-radius: 8px;
  padding: 8px 12px;
  color: #fff;
  background: var(--brand);
  cursor: pointer;
}

.danger {
  background: var(--danger);
}

.grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
  gap: 12px;
}

.error {
  color: var(--danger);
}

.message {
  color: var(--ok);
}
</style>
