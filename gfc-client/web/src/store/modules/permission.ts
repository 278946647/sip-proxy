import { ref } from 'vue'
import { defineStore } from 'pinia'
import { asyncRoutes } from '@/router/routes/async'
import { filterRoutesByPermission, toMenuTree } from '@/router/utils'
import type { AppRouteRecord, MenuItem } from '@/router/types'

export const usePermissionStore = defineStore('permission', () => {
  const dynamicRoutes = ref<AppRouteRecord[]>([])
  const menus = ref<MenuItem[]>([])

  async function generateRoutes(permissions: string[]) {
    dynamicRoutes.value = filterRoutesByPermission(asyncRoutes, permissions)
    menus.value = toMenuTree(dynamicRoutes.value)
  }

  return {
    dynamicRoutes,
    menus,
    generateRoutes,
  }
})
