import { del, get, post } from './http'

export const connectivityApi = {
  activation: () => get<Record<string, unknown>>('/activation'),
  flashCode: (code: string, resetState = false) => post<Record<string, unknown>>('/activation/flash', { code, reset_state: resetState }),
  clearActivation: () => del<Record<string, unknown>>('/activation'),
  nodes: () => get<Record<string, unknown>>('/nodes'),
  agent: () => get<Record<string, unknown>>('/agent'),
}
