import { asArray, asRecord, textValue } from '@/utils/data'

export function interfaceNames(payload: Record<string, unknown>) {
  return asArray(payload.interfaces).map((item) => textValue(item, '')).filter(Boolean)
}

export function networkWan(payload: Record<string, unknown>) {
  return textValue(payload.wan || payload.wanInterface || payload.wan_interface || 'ens160')
}

export function networkLan(payload: Record<string, unknown>) {
  return textValue(payload.lan || payload.lanInterface || payload.lan_interface || 'bridge_lan')
}

export function bridgeConfig(payload: Record<string, unknown>) {
  return asRecord(payload)
}

export function bridgeMembers(payload: Record<string, unknown>) {
  return asArray(payload.members).map((item) => textValue(item, '')).filter(Boolean)
}
