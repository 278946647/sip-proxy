import { get } from './http'

export const overviewApi = {
  status: () => get<Record<string, unknown>>('/status'),
  health: () => get<Record<string, unknown>>('/health'),
  metrics: () => get<Record<string, unknown>>('/metrics'),
  alerts: () => get<Record<string, unknown>>('/alerts'),
}
