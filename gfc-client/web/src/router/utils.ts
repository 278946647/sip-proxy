import type { AppRouteRecord, MenuItem } from './types'

function hasPermission(route: AppRouteRecord, permissions: string[]) {
  const required = route.meta.auths
  if (!required || required.length === 0) return true
  return required.some((code) => permissions.includes(code))
}

export function filterRoutesByPermission(routes: AppRouteRecord[], permissions: string[]): AppRouteRecord[] {
  return routes
    .filter((route) => hasPermission(route, permissions))
    .map((route) => {
      const next: AppRouteRecord = { ...route }
      if (route.children && route.children.length > 0) {
        next.children = filterRoutesByPermission(route.children, permissions)
      }
      return next
    })
    .filter((route) => !route.children || route.children.length > 0 || route.component)
}

export function toMenuTree(routes: AppRouteRecord[]): MenuItem[] {
  return routes
    .filter((route) => !route.meta.hidden)
    .map((route) => ({
      path: route.path,
      name: route.name,
      title: route.meta.title,
      icon: route.meta.icon,
      children: route.children ? toMenuTree(route.children) : undefined,
    }))
}
