import type { Pinia } from 'pinia'
import type { RouteRecordRaw, Router } from 'vue-router'
import { getToken } from '@/utils/auth'
import { usePermissionStore } from '@/store/modules/permission'
import { useUserStore } from '@/store/modules/user'

const WHITE_LIST = ['/login', '/flash.html']

export function setupGuards(router: Router, pinia: Pinia) {
  router.beforeEach(async (to, _from, next) => {
    const token = getToken()

    if (!token && !WHITE_LIST.includes(to.path)) {
      next({ path: '/login', query: { redirect: to.fullPath } })
      return
    }

    if (to.path === '/login' && token) {
      next({ path: '/overview/dashboard' })
      return
    }

    const userStore = useUserStore(pinia)
    const permissionStore = usePermissionStore(pinia)

    if (token && !userStore.initialized) {
      await userStore.bootstrap()
      await permissionStore.generateRoutes(userStore.permissions)
      permissionStore.dynamicRoutes.forEach((route) => router.addRoute(route as RouteRecordRaw))
      next({ ...to, replace: true })
      return
    }

    next()
  })
}
