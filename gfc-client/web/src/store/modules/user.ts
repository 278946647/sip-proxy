import { ref } from 'vue'
import { defineStore } from 'pinia'

const ADMIN_PERMISSIONS = [
  'overview:read',
  'network:read',
  'network:wan:read',
  'network:lan:read',
  'network:dhcp:read',
  'network:dns:read',
  'network:routes:read',
  'network:vlan:read',
  'network:interfaces:read',
  'policy:read',
  'policy:dns:read',
  'policy:rules:read',
  'policy:group:read',
  'policy:routing:read',
  'policy:firewall:read',
  'connectivity:read',
  'connectivity:platform:read',
  'connectivity:activation:read',
  'connectivity:nodes:read',
  'connectivity:tunnel:read',
  'connectivity:outbound:read',
  'connectivity:lines:read',
  'connectivity:failover:read',
  'connectivity:agent:read',
  'maintenance:read',
  'maintenance:metrics:read',
  'maintenance:services:read',
  'maintenance:logs:read',
  'maintenance:ssh:read',
  'maintenance:dataplane:read',
  'maintenance:upgrade:read',
  'maintenance:backup:read',
  'maintenance:diagnostics:read',
  'maintenance:settings:read',
]

export const useUserStore = defineStore('user', () => {
  const initialized = ref(false)
  const roles = ref<string[]>([])
  const permissions = ref<string[]>([])

  async function bootstrap() {
    roles.value = ['admin']
    permissions.value = [...ADMIN_PERMISSIONS]
    initialized.value = true
  }

  function reset() {
    initialized.value = false
    roles.value = []
    permissions.value = []
  }

  return {
    initialized,
    roles,
    permissions,
    bootstrap,
    reset,
  }
})
