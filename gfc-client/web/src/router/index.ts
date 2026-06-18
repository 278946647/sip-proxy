import { createRouter, createWebHistory, type RouteRecordRaw, type Router } from 'vue-router'
import type { Pinia } from 'pinia'
import { staticRoutes } from './routes/static'
import { setupGuards } from './guard'

const router = createRouter({
  history: createWebHistory(),
  routes: staticRoutes as RouteRecordRaw[],
})

export function setupRouterGuards(instance: Router, pinia: Pinia) {
  setupGuards(instance, pinia)
}

export default router
