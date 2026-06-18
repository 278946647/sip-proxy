import { get, put } from './http'

export const networkApi = {
  summary: () => get<Record<string, unknown>>('/network'),
  interfaces: () => get<Record<string, unknown>>('/network/interfaces'),
  bridge: () => get<Record<string, unknown>>('/network/bridge'),
  updateBridge: (payload: Record<string, unknown>) => put<Record<string, unknown>>('/network/bridge', payload),
}
