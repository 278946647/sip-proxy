export interface AppRouteMeta {
  title: string
  icon?: string
  rank?: number
  auths?: string[]
  hidden?: boolean
  keepAlive?: boolean
}

export interface AppRouteRecord {
  path: string
  name?: string
  redirect?: string
  component?: unknown
  children?: AppRouteRecord[]
  meta: AppRouteMeta
}

export interface MenuItem {
  path: string
  name?: string | symbol | null
  title: string
  icon?: string
  children?: MenuItem[]
}
