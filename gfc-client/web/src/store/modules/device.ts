import { ref } from 'vue'
import { defineStore } from 'pinia'
import { overviewApi } from '@/api/overview'

export const useDeviceStore = defineStore('device', () => {
  const loading = ref(false)
  const status = ref<Record<string, unknown>>({})

  async function refreshStatus() {
    loading.value = true
    try {
      const res = await overviewApi.status()
      if (res.ok) status.value = res.data
    } finally {
      loading.value = false
    }
  }

  return {
    loading,
    status,
    refreshStatus,
  }
})
