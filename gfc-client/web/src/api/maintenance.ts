import { get, post, put } from './http'

export const maintenanceApi = {
  services: () => get<Record<string, unknown>>('/services'),
  restartService: (name: string) => post<Record<string, unknown>>(`/services/${name}/restart`),
  logs: (service = 'agent', lines = 200) => get<Record<string, unknown>>('/logs', { service, lines }),
  dnsStats: () => get<Record<string, unknown>>('/dns/stats'),
  singboxStats: () => get<Record<string, unknown>>('/singbox/stats'),
  dataplaneReload: () => post<Record<string, unknown>>('/dataplane/reload'),
  dataplaneApply: () => post<Record<string, unknown>>('/dataplane/apply'),
  dataplaneRollback: () => post<Record<string, unknown>>('/dataplane/rollback'),
  upgradeStatus: () => get<Record<string, unknown>>('/upgrade/status'),
  upgradeCheck: (manifestUrl = '') => post<Record<string, unknown>>('/upgrade/check', { manifest_url: manifestUrl }),
  settings: () => get<Record<string, unknown>>('/settings'),
  updateSettings: (payload: Record<string, unknown>) => put<Record<string, unknown>>('/settings', payload),
  updateSingboxLogging: (level: string) => put<Record<string, unknown>>('/settings/singbox/logging', { level }),
}
