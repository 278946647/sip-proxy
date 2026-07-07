import type { AppRouteRecord } from '@/router/types'

const Layout = () => import('@/layout/index.vue')
const Placeholder = () => import('@/views/shared/SectionPlaceholder.vue')
const DashboardPage = () => import('@/views/overview/dashboard/index.vue')
const NetworkSummaryPage = () => import('@/views/network/summary/index.vue')
const NetworkWanPage = () => import('@/views/network/wan/index.vue')
const NetworkLanPage = () => import('@/views/network/lan/index.vue')
const NetworkDhcpPage = () => import('@/views/network/dhcp/index.vue')
const NetworkDnsUpstreamPage = () => import('@/views/network/dns-upstream/index.vue')
const NetworkRoutesPage = () => import('@/views/network/routes/index.vue')
const NetworkVlanPage = () => import('@/views/network/vlan/index.vue')
const NetworkInterfacesPage = () => import('@/views/network/interfaces/index.vue')
const NetworkTrafficPage = () => import('@/views/network/traffic/index.vue')
const PolicySummaryPage = () => import('@/views/policy/summary/index.vue')
const PolicyDnsListsPage = () => import('@/views/policy/dns-lists/index.vue')
const PolicyProxyGroupsPage = () => import('@/views/policy/proxy-groups/index.vue')
const PolicyRoutingPage = () => import('@/views/policy/routing/index.vue')
const PolicyRuleSetsPage = () => import('@/views/policy/rule-sets/index.vue')
const PolicyFirewallPage = () => import('@/views/policy/firewall/index.vue')
const ConnectivityActivationPage = () => import('@/views/connectivity/activation/index.vue')
const ConnectivityNodesPage = () => import('@/views/connectivity/nodes/index.vue')
const ConnectivityAgentPage = () => import('@/views/connectivity/agent/index.vue')
const MaintenanceServicesPage = () => import('@/views/maintenance/services/index.vue')
const MaintenanceLogsPage = () => import('@/views/maintenance/logs/index.vue')
const MaintenanceDataplanePage = () => import('@/views/maintenance/dataplane/index.vue')
const MaintenanceUpgradePage = () => import('@/views/maintenance/upgrade/index.vue')
const MaintenanceSettingsPage = () => import('@/views/maintenance/settings/index.vue')
const MaintenanceDiagnosticsPage = () => import('@/views/maintenance/diagnostics/index.vue')

function page(path: string, name: string, title: string, auths: string[]): AppRouteRecord {
  return {
    path,
    name,
    component: Placeholder,
    meta: { title, auths },
  }
}

export const asyncRoutes: AppRouteRecord[] = [
  {
    path: '/overview',
    name: 'Overview',
    component: Layout,
    redirect: '/overview/dashboard',
    meta: { title: '概览', icon: 'overview', rank: 1 },
    children: [
      { path: 'dashboard', name: 'OverviewDashboard', component: DashboardPage, meta: { title: 'Dashboard', auths: ['overview:read'] } },
      { path: 'device', name: 'OverviewDevice', component: DashboardPage, meta: { title: '设备状态', auths: ['overview:read'] } },
      { path: 'alerts', name: 'OverviewAlerts', component: DashboardPage, meta: { title: '告警中心', auths: ['overview:read'] } },
      { path: 'health', name: 'OverviewHealth', component: DashboardPage, meta: { title: '健康度', auths: ['overview:read'] } },
    ],
  },
  {
    path: '/network',
    name: 'Network',
    component: Layout,
    redirect: '/network/summary',
    meta: { title: '网络', icon: 'network', rank: 2 },
    children: [
      { path: 'summary', name: 'NetworkSummary', component: NetworkSummaryPage, meta: { title: '网络总览', auths: ['network:read'] } },
      { path: 'wan', name: 'NetworkWan', component: NetworkWanPage, meta: { title: 'WAN 配置', auths: ['network:wan:read'] } },
      { path: 'lan', name: 'NetworkLan', component: NetworkLanPage, meta: { title: 'LAN / 桥接', auths: ['network:lan:read'] } },
      { path: 'dhcp', name: 'NetworkDhcp', component: NetworkDhcpPage, meta: { title: 'DHCP 服务', auths: ['network:dhcp:read'] } },
      { path: 'dns-upstream', name: 'NetworkDnsUpstream', component: NetworkDnsUpstreamPage, meta: { title: 'DNS 上游', auths: ['network:dns:read'] } },
      { path: 'routes', name: 'NetworkRoutes', component: NetworkRoutesPage, meta: { title: '静态路由', auths: ['network:routes:read'] } },
      { path: 'vlan', name: 'NetworkVlan', component: NetworkVlanPage, meta: { title: 'VLAN', auths: ['network:vlan:read'] } },
      { path: 'interfaces', name: 'NetworkInterfaces', component: NetworkInterfacesPage, meta: { title: '接口管理', auths: ['network:interfaces:read'] } },
      { path: 'traffic', name: 'NetworkTraffic', component: NetworkTrafficPage, meta: { title: '接口流量', auths: ['network:read'] } },
    ],
  },
  {
    path: '/policy',
    name: 'Policy',
    component: Layout,
    redirect: '/policy/summary',
    meta: { title: '策略', icon: 'policy', rank: 3 },
    children: [
      { path: 'summary', name: 'PolicySummary', component: PolicySummaryPage, meta: { title: '策略总览', auths: ['policy:read'] } },
      { path: 'dns-split', name: 'PolicyDnsSplit', component: PolicyDnsListsPage, meta: { title: 'DNS 分流', auths: ['policy:dns:read'] } },
      { path: 'domain-lists', name: 'PolicyDomainLists', component: PolicyDnsListsPage, meta: { title: '域名列表', auths: ['policy:dns:read'] } },
      { path: 'geosite', name: 'PolicyGeosite', component: PolicyRuleSetsPage, meta: { title: 'GeoSite 规则', auths: ['policy:rules:read'] } },
      { path: 'geoip', name: 'PolicyGeoip', component: PolicyRuleSetsPage, meta: { title: 'GeoIP 规则', auths: ['policy:rules:read'] } },
      { path: 'proxy-groups', name: 'PolicyProxyGroups', component: PolicyProxyGroupsPage, meta: { title: '代理策略组', auths: ['policy:group:read'] } },
      { path: 'routing', name: 'PolicyRouting', component: PolicyRoutingPage, meta: { title: '策略路由', auths: ['policy:routing:read'] } },
      { path: 'firewall', name: 'PolicyFirewall', component: PolicyFirewallPage, meta: { title: 'nftables', auths: ['policy:firewall:read'] } },
      { path: 'rule-sets', name: 'PolicyRuleSets', component: PolicyRuleSetsPage, meta: { title: '规则集管理', auths: ['policy:rules:read'] } },
    ],
  },
  {
    path: '/connectivity',
    name: 'Connectivity',
    component: Layout,
    redirect: '/connectivity/activation',
    meta: { title: '线路', icon: 'connectivity', rank: 4 },
    children: [
      { path: 'summary', name: 'ConnectivitySummary', component: ConnectivityActivationPage, meta: { title: '线路总览', auths: ['connectivity:read'] } },
      { path: 'platform', name: 'ConnectivityPlatform', component: ConnectivityActivationPage, meta: { title: '控制平台注册', auths: ['connectivity:platform:read'] } },
      { path: 'activation', name: 'ConnectivityActivation', component: ConnectivityActivationPage, meta: { title: '激活状态', auths: ['connectivity:activation:read'] } },
      { path: 'nodes', name: 'ConnectivityNodes', component: ConnectivityNodesPage, meta: { title: '节点列表', auths: ['connectivity:nodes:read'] } },
      { path: 'tunnel', name: 'ConnectivityTunnel', component: ConnectivityAgentPage, meta: { title: 'Tunnel 状态', auths: ['connectivity:tunnel:read'] } },
      { path: 'outbound', name: 'ConnectivityOutbound', component: ConnectivityNodesPage, meta: { title: 'VLESS / REALITY', auths: ['connectivity:outbound:read'] } },
      { path: 'lines', name: 'ConnectivityLines', component: ConnectivityNodesPage, meta: { title: '多线路管理', auths: ['connectivity:lines:read'] } },
      { path: 'failover', name: 'ConnectivityFailover', component: ConnectivityNodesPage, meta: { title: '故障切换', auths: ['connectivity:failover:read'] } },
      { path: 'agent', name: 'ConnectivityAgent', component: ConnectivityAgentPage, meta: { title: 'Agent 同步状态', auths: ['connectivity:agent:read'] } },
    ],
  },
  {
    path: '/maintenance',
    name: 'Maintenance',
    component: Layout,
    redirect: '/maintenance/services',
    meta: { title: '运维', icon: 'maintenance', rank: 5 },
    children: [
      { path: 'monitor', name: 'MaintenanceMonitor', component: DashboardPage, meta: { title: '监控总览', auths: ['maintenance:read'] } },
      { path: 'metrics', name: 'MaintenanceMetrics', component: DashboardPage, meta: { title: '系统指标', auths: ['maintenance:metrics:read'] } },
      { path: 'services', name: 'MaintenanceServices', component: MaintenanceServicesPage, meta: { title: '服务状态', auths: ['maintenance:services:read'] } },
      { path: 'logs', name: 'MaintenanceLogs', component: MaintenanceLogsPage, meta: { title: '日志中心', auths: ['maintenance:logs:read'] } },
      page('ssh', 'MaintenanceSsh', '远程 SSH', ['maintenance:ssh:read']),
      { path: 'dataplane', name: 'MaintenanceDataplane', component: MaintenanceDataplanePage, meta: { title: '配置应用 / 回滚', auths: ['maintenance:dataplane:read'] } },
      { path: 'upgrade', name: 'MaintenanceUpgrade', component: MaintenanceUpgradePage, meta: { title: '系统升级', auths: ['maintenance:upgrade:read'] } },
      page('backup', 'MaintenanceBackup', '备份与恢复', ['maintenance:backup:read']),
      { path: 'diagnostics', name: 'MaintenanceDiagnostics', component: MaintenanceDiagnosticsPage, meta: { title: '诊断工具', auths: ['maintenance:diagnostics:read'] } },
      { path: 'settings', name: 'MaintenanceSettings', component: MaintenanceSettingsPage, meta: { title: '系统设置', auths: ['maintenance:settings:read'] } },
    ],
  },
]
