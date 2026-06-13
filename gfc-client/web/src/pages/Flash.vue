<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { flashCode } from '../api'

const code = ref('')
const msg = ref('')
const err = ref('')
const loading = ref(false)

async function submit() {
  err.value = ''
  msg.value = ''
  loading.value = true
  try {
    const r = await flashCode(code.value.trim(), true)
    msg.value = String(r.message || '刷码成功')
  } catch (e: unknown) {
    err.value = String(e)
  } finally {
    loading.value = false
  }
}
</script>

<template>
  <h1 class="page-title">刷入线路码</h1>
  <div class="card">
    <p style="color: var(--muted); margin-top: 0">
      粘贴控制平台生成的 Base32 线路码。刷码后 Agent 将自动联网激活。
    </p>
    <textarea v-model="code" rows="8" placeholder="粘贴线路码…" />
    <div style="margin-top: 1rem">
      <button class="btn" :disabled="loading || !code.trim()" @click="submit">
        {{ loading ? '提交中…' : '刷入线路码' }}
      </button>
    </div>
    <div v-if="msg" class="msg" style="color: var(--ok)">{{ msg }}</div>
    <div v-if="err" class="msg" style="color: var(--err)">{{ err }}</div>
  </div>
</template>
