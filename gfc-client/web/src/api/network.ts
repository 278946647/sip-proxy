import { get, put } from './http'

export const networkApi = {
  summary: () => get<Record<string, unknown>>('/network'),
  interfaces: () => get<Record<string, unknown>>('/network/interfaces'),
  bridge: () => get<Record<string, unknown>>('/network/bridge'),
  updateBridge: (payload: Record<string, unknown>) => put<Record<string, unknown>>('/network/bridge', payload),
  wan: () => get<Record<string, unknown>>('/network/wan'),
  updateWan: (payload: Record<string, unknown>) => put<Record<string, unknown>>('/network/wan', payload),
  dhcp: () => get<Record<string, unknown>>('/network/dhcp'),
  updateDhcp: (payload: Record<string, unknown>) => put<Record<string, unknown>>('/network/dhcp', payload),
  routes: () => get<Record<string, unknown>>('/network/routes'),
  updateRoutes: (payload: Record<string, unknown>) => put<Record<string, unknown>>('/network/routes', payload),
  vlan: () => get<Record<string, unknown>>('/network/vlan'),
  updateVlan: (payload: Record<string, unknown>) => put<Record<string, unknown>>('/network/vlan', payload),
  trafficHistory: (hours = 24, iface = 'gfctun') =>
    get<Record<string, unknown>>(`/network/traffic/history?hours=${hours}&iface=${encodeURIComponent(iface)}`),
  trafficInterfaces: (includeTunnel = true) =>
    get<Record<string, unknown>>(`/network/traffic/interfaces?include_tunnel=${includeTunnel ? '1' : '0'}`),
}
