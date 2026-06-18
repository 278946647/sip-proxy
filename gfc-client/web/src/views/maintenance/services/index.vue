<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import JsonBlock from '@/components/common/JsonBlock.vue'
import { maintenanceApi } from '@/api/maintenance'
import { asRecord, textValue } from '@/utils/data'

const loading = ref(false)
const actionLoading = ref('')
const error = ref('')
const message = ref('')
const services = ref<Record<string, unknown>>({})

const serviceRows = computed(() => {
  const list = services.value.services
  if (Array.isArray(list)) return list.map(asRecord)
  return Object.entries(asRecord(list)).map(([name, value]) => ({ name, ...asRecord(value) }))
})

async function load() {
  loading.value = true
  error.value = ''
  try {
    const res = await maintenanceApi.services()
    if (res.ok) services.value = res.data
  } catch (err) {
    error.value = String(err)
  } finally {
    loading.value = false
  }
}

async function restart(name: string) {
  if (!name) return
  actionLoading.value = name
  message.value = ''
  try {
    const res = await maintenanceApi.restartService(name)
    message.value = res.ok ? `${name} 重启命令已发送` : (res.error?.message ?? `${name} 重启失败`)
    await load()
  } catch (err) {
    message.value = String(err)
  } finally {
    actionLoading.value = ''
  }
}

async function dataplane(action: 'reload' | 'apply' | 'rollback') {
  actionLoading.value = action
  message.value = ''
  try {
    const api = action === 'reload' ? maintenanceApi.dataplaneReload : action === 'apply' ? maintenanceApi.dataplaneApply : maintenanceApi.dataplaneRollback
    const res = await api()
    message.value = res.ok ? `数据面 ${action} 完成` : (res.error?.message ?? `数据面 ${action} 失败`)
  } catch (err) {
    message.value = String(err)
  } finally {
    actionLoading.value = ''
  }
}

function serviceName(row: Record<string, unknown>) {
  return textValue(row.name || row.service || row.unit, '')
}

function serviceStatus(row: Record<string, unknown>) {
  return textValue(row.status || row.active || row.state || row.sub)
}

onMounted(load)
</script>

<template>
  <section class="page">
    <header class="page-head">
      <div>
        <h2>服务状态</h2>
        <p>查看 systemd 服务状态，支持重启核心服务与数据面应用/回滚。</p>
      </div>
      <button :disabled="loading" @click="load">{{ loading ? '刷新中...' : '刷新' }}</button>
    </header>

    <div class="actions">
      <button :disabled="!!actionLoading" @click="dataplane('reload')">重载数据面</button>
      <button :disabled="!!actionLoading" @click="dataplane('apply')">应用配置</button>
      <button class="danger" :disabled="!!actionLoading" @click="dataplane('rollback')">回滚配置</button>
    </div>

    <div v-if="message" class="message">{{ message }}</div>
    <div v-if="error" class="error">{{ error }}</div>

    <div class="card">
      <table v-if="serviceRows.length">
        <thead>
          <tr>
            <th>服务</th>
            <th>状态</th>
            <th>操作</th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="(row, index) in serviceRows" :key="`${serviceName(row)}-${index}`">
            <td>{{ serviceName(row) || `service-${index + 1}` }}</td>
            <td>{{ serviceStatus(row) }}</td>
            <td>
              <button
                v-if="serviceName(row)"
                class="small"
                :disabled="actionLoading === serviceName(row)"
                @click="restart(serviceName(row))"
              >
                重启
              </button>
            </td>
          </tr>
        </tbody>
      </table>
      <p v-else>暂无服务列表，查看下方原始响应。</p>
    </div>

    <JsonBlock title="服务原始响应 /services" :data="services" />
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
p {
  margin: 0;
}

p {
  margin-top: 4px;
  color: var(--muted);
}

.actions {
  display: flex;
  flex-wrap: wrap;
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

.small {
  padding: 4px 8px;
}

.danger {
  background: var(--danger);
}

.card {
  background: var(--panel);
  border: 1px solid var(--border);
  border-radius: 10px;
  overflow: auto;
}

table {
  width: 100%;
  border-collapse: collapse;
}

th,
td {
  text-align: left;
  border-bottom: 1px solid var(--border);
  padding: 9px 10px;
}

th {
  background: #f8fafc;
}

.error {
  color: var(--danger);
}

.message {
  color: var(--ok);
}
</style>
