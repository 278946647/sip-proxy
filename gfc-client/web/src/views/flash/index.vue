<script setup lang="ts">
import { ref } from 'vue'
import { connectivityApi } from '@/api/connectivity'

const code = ref('')
const result = ref('')
const loading = ref(false)

async function flash() {
  loading.value = true
  result.value = ''
  try {
    const res = await connectivityApi.flashCode(code.value, false)
    result.value = res.ok ? '刷码成功' : (res.error?.message ?? '刷码失败')
  } catch (error) {
    result.value = `刷码失败: ${String(error)}`
  } finally {
    loading.value = false
  }
}
</script>

<template>
  <div class="wrap">
    <div class="card">
      <h1>线路码激活</h1>
      <textarea v-model="code" rows="6" placeholder="粘贴线路码..." />
      <button :disabled="loading" @click="flash">{{ loading ? '提交中...' : '立即刷码' }}</button>
      <p>{{ result }}</p>
    </div>
  </div>
</template>

<style scoped>
.wrap {
  min-height: 100%;
  display: grid;
  place-items: center;
  padding: 20px;
}

.card {
  width: min(560px, 100%);
  background: var(--panel);
  border: 1px solid var(--border);
  border-radius: 12px;
  padding: 16px;
  display: grid;
  gap: 10px;
}

h1 {
  margin: 0;
  font-size: 20px;
}

textarea {
  resize: vertical;
  border: 1px solid var(--border);
  border-radius: 8px;
  padding: 8px;
}

button {
  border: 0;
  color: #fff;
  background: var(--brand);
  border-radius: 8px;
  padding: 8px;
}

p {
  margin: 0;
  min-height: 1.2em;
  color: var(--muted);
}
</style>
