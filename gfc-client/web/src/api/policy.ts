import { get, post, put } from './http'

export const policyApi = {
  groups: () => get<Record<string, unknown>>('/policy/groups'),
  selectGroup: (id: string, outbound: string) => put<Record<string, unknown>>(`/policy/groups/${id}/select`, { outbound }),
  dnsLists: () => get<Record<string, unknown>>('/dns/lists'),
  exportDnsList: (name: string) => get<Record<string, unknown>>(`/dns/lists/${name}`),
  updateDnsList: (name: string, payload: Record<string, unknown>) => post<Record<string, unknown>>(`/dns/lists/${name}`, payload),
  importDnsList: (name: string, payload: Record<string, unknown>) => post<Record<string, unknown>>(`/dns/lists/${name}/import`, payload),
  easyMosdnsUpdate: () => post<Record<string, unknown>>('/dns/easymosdns/update'),
  rules: () => get<Record<string, unknown>>('/rules'),
  updateRules: () => post<Record<string, unknown>>('/rules/update'),
  routing: () => get<Record<string, unknown>>('/routing'),
  updateRouting: (mode: string) => put<Record<string, unknown>>('/routing', { mode }),
  firewall: () => get<Record<string, unknown>>('/policy/firewall'),
}
