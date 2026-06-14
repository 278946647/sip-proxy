import axios from 'axios'

const api = axios.create({ baseURL: '/api/v1', timeout: 30000 })

api.interceptors.response.use(
  (r) => r,
  (e) => Promise.reject(e.response?.data?.error?.message || e.message)
)

export async function getStatus() {
  const { data } = await api.get('/status')
  return data.data
}

export async function getHealth() {
  const { data } = await api.get('/health')
  return data.data
}

export async function flashCode(code: string, resetState = true) {
  const { data } = await api.post('/activation/flash', { code, reset_state: resetState })
  return data.data
}

export async function getNodes() {
  const { data } = await api.get('/nodes')
  return data.data.nodes
}

export async function getPolicyGroups() {
  const { data } = await api.get('/policy/groups')
  return data.data.groups
}

export async function selectPolicy(id: string, outbound: string) {
  const { data } = await api.put(`/policy/groups/${id}/select`, { outbound })
  return data.data
}

export async function getDNSStats() {
  const { data } = await api.get('/dns/stats')
  return data.data
}

export async function getSingboxStats() {
  const { data } = await api.get('/singbox/stats')
  return data.data
}

export async function getAgent() {
  const { data } = await api.get('/agent')
  return data.data
}

export async function checkUpgrade(manifestURL?: string) {
  const { data } = await api.post('/upgrade/check', manifestURL ? { manifest_url: manifestURL } : {})
  return data.data
}

export async function getUpgradeStatus() {
  const { data } = await api.get('/upgrade/status')
  return data.data
}

export async function getDNSLists() {
  const { data } = await api.get('/dns/lists')
  return data.data
}

export async function updateDNS(name: string, domains: string[], action: string) {
  const { data } = await api.post(`/dns/lists/${name}`, { domains, action })
  return data.data
}

export async function getRules() {
  const { data } = await api.get('/rules')
  return data.data.rules
}

export async function updateRules() {
  const { data } = await api.post('/rules/update')
  return data.data
}

export async function getRouting() {
  const { data } = await api.get('/routing')
  return data.data
}

export async function setRouting(mode: string) {
  const { data } = await api.put('/routing', { mode })
  return data.data
}

export async function getServices() {
  const { data } = await api.get('/services')
  return data.data.services
}

export async function restartService(name: string) {
  const { data } = await api.post(`/services/${name}/restart`)
  return data.data
}

export async function reloadDataplane() {
  const { data } = await api.post('/dataplane/reload')
  return data.data
}

export async function getNetwork() {
  const { data } = await api.get('/network')
  return data.data
}

export async function getLogs(service: string, lines = 200) {
  const { data } = await api.get('/logs', { params: { service, lines } })
  return data.data
}

export async function getSettings() {
  const { data } = await api.get('/settings')
  return data.data
}

export async function putSettings(body: Record<string, unknown>) {
  const { data } = await api.put('/settings', body)
  return data.data
}

export async function setLogLevel(level: string) {
  const { data } = await api.put('/settings/singbox/logging', { level })
  return data.data
}

export async function easyMosdnsUpdate() {
  const { data } = await api.post('/dns/easymosdns/update', { source: 'github' })
  return data.data
}

export default api
