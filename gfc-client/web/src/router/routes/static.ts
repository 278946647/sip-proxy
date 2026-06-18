import type { AppRouteRecord } from '@/router/types'

export const staticRoutes: AppRouteRecord[] = [
  {
    path: '/login',
    name: 'Login',
    component: () => import('@/views/login/index.vue'),
    meta: { title: '登录', hidden: true },
  },
  {
    path: '/flash.html',
    name: 'Flash',
    component: () => import('@/views/flash/index.vue'),
    meta: { title: '刷码', hidden: true },
  },
  {
    path: '/',
    name: 'Root',
    redirect: '/overview/dashboard',
    meta: { title: 'Root', hidden: true },
  },
  {
    path: '/:pathMatch(.*)*',
    name: 'NotFound',
    component: () => import('@/views/error/404.vue'),
    meta: { title: '404', hidden: true },
  },
]
