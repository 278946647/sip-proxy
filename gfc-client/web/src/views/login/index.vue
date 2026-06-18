<script setup lang="ts">
import { ref } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { setToken } from '@/utils/auth'

const route = useRoute()
const router = useRouter()
const token = ref('')
const error = ref('')

function submit() {
  if (!token.value.trim()) {
    error.value = '请输入管理 Token'
    return
  }
  setToken(token.value.trim())
  const redirect = typeof route.query.redirect === 'string' ? route.query.redirect : '/overview/dashboard'
  router.push(redirect)
}

function enterLocalMode() {
  setToken('local-admin')
  const redirect = typeof route.query.redirect === 'string' ? route.query.redirect : '/overview/dashboard'
  router.push(redirect)
}
</script>

<template>
  <div class="login-wrap">
    <form class="card" @submit.prevent="submit">
      <h1>GFC Client 管理登录</h1>
      <p>输入设备管理 Token 进入后台。</p>
      <label for="token">X-GFC-Token</label>
      <input id="token" v-model="token" autocomplete="off" />
      <div v-if="error" class="error">{{ error }}</div>
      <button type="submit">登录</button>
      <button class="ghost" type="button" @click="enterLocalMode">本地设备模式进入</button>
    </form>
  </div>
</template>

<style scoped>
.login-wrap {
  height: 100%;
  display: grid;
  place-items: center;
  padding: 24px;
}

.card {
  width: min(440px, 100%);
  background: var(--panel);
  border: 1px solid var(--border);
  border-radius: 12px;
  padding: 20px;
  display: grid;
  gap: 10px;
}

h1 {
  margin: 0;
  font-size: 20px;
}

p {
  margin: 0 0 8px;
  color: var(--muted);
}

input {
  border: 1px solid var(--border);
  border-radius: 8px;
  padding: 8px 10px;
}

button {
  margin-top: 6px;
  border: 0;
  border-radius: 8px;
  color: white;
  background: var(--brand);
  padding: 9px 12px;
  cursor: pointer;
}

.ghost {
  color: var(--brand);
  background: var(--brand-soft);
}

.error {
  color: var(--danger);
}
</style>
