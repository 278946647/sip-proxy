<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { connectivityApi } from '@/api/connectivity'

const code = ref('')
const result = ref('')
const loading = ref(false)
const resetState = ref(true)
const activation = ref<Record<string, unknown>>({})

const luciAdminHref = computed(() => `http://${window.location.hostname}/cgi-bin/luci/admin/gfc/status/overview`)

async function loadStatus() {
  try {
    const res = await connectivityApi.activation()
    if (res.ok) activation.value = res.data
  } catch {
  }
}

async function flash() {
  if (!code.value.trim()) {
    result.value = '请粘贴线路码'
    return
  }
  loading.value = true
  result.value = ''
  try {
    const res = await connectivityApi.flashCode(code.value.trim(), resetState.value)
    result.value = res.ok ? '刷码成功，设备正在连接控制面' : (res.error?.message ?? '刷码失败')
    if (res.ok) {
      code.value = ''
      await loadStatus()
    }
  } catch (error) {
    result.value = `刷码失败: ${String(error)}`
  } finally {
    loading.value = false
  }
}

onMounted(loadStatus)
</script>

<template>
  <div class="wrap">
    <div class="shell">
      <header class="brand">
        <div>
          <h1>GFC 终端盒子</h1>
          <p>设备激活 · 无需管理账号</p>
        </div>
      </header>

      <div class="grid">
        <section class="card main">
          <h2>刷入线路码</h2>
          <p class="hint">粘贴控制平台生成的线路码，提交后 Agent 将自动拉取节点与策略。</p>
          <textarea v-model="code" rows="7" placeholder="粘贴线路码…" spellcheck="false" />
          <label class="check">
            <input v-model="resetState" type="checkbox" />
            重置本地状态后刷入
          </label>
          <button :disabled="loading" @click="flash">{{ loading ? '提交中…' : '立即激活' }}</button>
          <p class="result" :class="{ ok: result.includes('成功') }">{{ result }}</p>
        </section>

        <aside class="card side">
          <h2>激活状态</h2>
          <div class="stat">
            <span>线路码</span>
            <strong>{{ activation.code_present ? '已写入' : '未激活' }}</strong>
          </div>
          <div class="links">
            <a :href="luciAdminHref">进入管理后台</a>
          </div>
        </aside>
      </div>
    </div>
  </div>
</template>

<style scoped>
.wrap {
  min-height: 100%;
  padding: 24px;
  background: radial-gradient(circle at top, #dbeafe 0%, #f8fafc 55%);
}

.shell {
  width: min(920px, 100%);
  margin: 0 auto;
  display: grid;
  gap: 16px;
}

.brand {
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 12px;
}

.brand h1 {
  margin: 0;
  font-size: 22px;
}

.brand p {
  margin: 4px 0 0;
  color: var(--muted);
  font-size: 13px;
}

.ghost-link {
  color: var(--brand);
  text-decoration: none;
  border: 1px solid var(--brand);
  border-radius: 8px;
  padding: 8px 12px;
  font-size: 13px;
}

.grid {
  display: grid;
  grid-template-columns: 1.2fr 0.8fr;
  gap: 14px;
}

@media (max-width: 800px) {
  .grid {
    grid-template-columns: 1fr;
  }
}

.card {
  background: var(--panel);
  border: 1px solid var(--border);
  border-radius: 12px;
  padding: 16px;
  display: grid;
  gap: 10px;
}

h2 {
  margin: 0;
  font-size: 17px;
}

.hint {
  margin: 0;
  color: var(--muted);
  font-size: 13px;
  line-height: 1.5;
}

textarea {
  resize: vertical;
  border: 1px solid var(--border);
  border-radius: 8px;
  padding: 8px;
  font-family: ui-monospace, monospace;
  font-size: 13px;
}

.check {
  display: flex;
  gap: 6px;
  align-items: center;
  color: var(--muted);
  font-size: 13px;
}

button {
  border: 0;
  color: #fff;
  background: var(--brand);
  border-radius: 8px;
  padding: 9px 12px;
  cursor: pointer;
}

.stat {
  background: #f8fafc;
  border: 1px solid var(--border);
  border-radius: 8px;
  padding: 10px;
}

.stat span {
  display: block;
  color: var(--muted);
  font-size: 12px;
}

.stat strong {
  font-size: 15px;
}

.links {
  display: grid;
  gap: 8px;
}

.links a {
  color: var(--brand);
  font-size: 13px;
}

.result {
  margin: 0;
  min-height: 1.2em;
  color: var(--danger);
  font-size: 13px;
}

.result.ok {
  color: var(--ok);
}
</style>
