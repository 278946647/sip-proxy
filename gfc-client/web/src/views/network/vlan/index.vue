<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import ConfigPanel from '@/components/business/ConfigPanel.vue'
import DataTable from '@/components/common/DataTable.vue'
import JsonBlock from '@/components/common/JsonBlock.vue'
import { networkApi } from '@/api/network'
import { asArray, asRecord } from '@/utils/data'

const loading = ref(false)
const saving = ref(false)
const message = ref('')
const error = ref('')
const payload = ref<Record<string, unknown>>({})
const form = ref({ id: 10, name: '', interface: '', address: '', dhcp: false })

const rows = computed(() => asArray(payload.value.vlans).map(asRecord))

async function load() {
  loading.value = true
  error.value = ''
  try {
    const res = await networkApi.vlan()
    if (res.ok) payload.value = res.data
  } catch (err) {
    error.value = String(err)
  } finally {
    loading.value = false
  }
}

async function save(vlans: Array<Record<string, unknown>>) {
  saving.value = true
  message.value = ''
  try {
    const res = await networkApi.updateVlan({ vlans })
    message.value = res.ok ? 'VLAN 配置已保存。' : (res.error?.message ?? '保存失败')
    await load()
  } catch (err) {
    message.value = String(err)
  } finally {
    saving.value = false
  }
}

function addVlan() {
  if (!form.value.id || !form.value.interface) {
    message.value = '请输入 VLAN ID 和父接口'
    return
  }
  save([...rows.value, { ...form.value }])
  form.value = { id: 10, name: '', interface: '', address: '', dhcp: false }
}

function removeVlan(index: number) {
  save(rows.value.filter((_, i) => i !== index))
}

onMounted(load)
</script>

<template>
  <section class="page">
    <header class="page-head">
      <div><h2>VLAN</h2><p>维护 VLAN 子接口模型，应用脚本会读取配置生成实际网络。</p></div>
      <button :disabled="loading" @click="load">刷新</button>
    </header>
    <div v-if="message" class="notice">{{ message }}</div>
    <div v-if="error" class="error">{{ error }}</div>
    <ConfigPanel title="新增 VLAN">
      <div class="form-grid">
        <label>VLAN ID <input v-model.number="form.id" type="number" /></label>
        <label>名称 <input v-model="form.name" placeholder="office" /></label>
        <label>父接口 <input v-model="form.interface" placeholder="ens224" /></label>
        <label>地址 <input v-model="form.address" placeholder="192.168.10.1/24" /></label>
        <label class="switch"><input v-model="form.dhcp" type="checkbox" /> 启用 DHCP</label>
      </div>
      <div class="actions"><button :disabled="saving" @click="addVlan">添加并保存</button></div>
    </ConfigPanel>
    <DataTable :columns="[
      { key: 'id', title: 'VLAN ID' },
      { key: 'name', title: '名称' },
      { key: 'interface', title: '父接口' },
      { key: 'address', title: '地址' },
      { key: 'dhcp', title: 'DHCP' },
    ]" :rows="rows">
      <template #actions="{ index }">
        <button class="danger" :disabled="saving" @click="removeVlan(index)">删除</button>
      </template>
    </DataTable>
    <JsonBlock title="VLAN 调试数据" :data="payload" />
  </section>
</template>

<style scoped>
.page{display:grid;gap:12px}.page-head{display:flex;justify-content:space-between;align-items:center;gap:12px}h2,p{margin:0}p{margin-top:4px;color:var(--muted)}button{border:0;border-radius:4px;padding:7px 12px;color:#fff;background:#2563eb;cursor:pointer}.danger{background:var(--danger)}.form-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:12px}label{display:grid;gap:5px;color:#334155;font-size:13px}.switch{display:flex;gap:8px;align-items:center}input{border:1px solid var(--border);border-radius:4px;padding:7px;background:#fff}.actions{margin-top:12px}.notice{padding:8px 10px;border:1px solid #bbf7d0;background:#f0fdf4;color:#15803d;border-radius:4px}.error{color:var(--danger)}
</style>
