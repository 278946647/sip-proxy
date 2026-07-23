export type Dashboard = {
  nodeTotal: number;
  nodeOnline: number;
  lineTotal: number;
  lineActive: number;
  socksTotal: number;
  socksOnline: number;
  socksOffline: number;
  alertOpen: number;
  socksAlertOpen: number;
};

export type NodeRow = {
  id: number;
  nodeKey: string;
  name: string;
  region: string;
  country: string;
  publicIp: string | null;
  isActive: boolean;
  online: boolean;
  lastSeenAt: string | null;
  currentConfigVersion: string | null;
  createdAt: string | null;
  monthlyQuotaGb: number | null;
  quotaUsedPercent: number | null;
};

export type LineListItem = {
  id: number;
  tid: string;
  name: string;
  nodeId: number;
  nodeName: string;
  country: string;
  bandwidthMbps: number;
  remark: string | null;
  isEnabled: boolean;
  status: string;
  createdAt: string;
  socksProfileId: number | null;
  socksName: string | null;
  lineType: string;
  clientDeviceId: number | null;
  clientDeviceName: string | null;
};

export type PaginatedLines = {
  total: number;
  items: LineListItem[];
};

export type LineDetail = LineListItem & {
  sourceCidrs: string[];
  socksRemark: string | null;
  createdBy: string;
  socksHost: string | null;
  socksPort: number | null;
  socksUsername: string | null;
  socksPassword: string | null;
  clientSocksDisplay: string;
  currentConfigVersion: string | null;
  clientUuid: string | null;
  lineCodeB32: string | null;
  flowStatsEnabled: boolean;
  socksUdpOverTcp: boolean;
};

export type DeviceProxyMode = "gateway" | "bypass" | "transparent";
export type DeviceRoutingScheme = "split" | "global";

export type ClientDeviceListItem = {
  id: number;
  name: string;
  deviceKey: string;
  lanMac: string | null;
  deviceId: string | null;
  lineId: number | null;
  lineTid: string | null;
  reverseSshPort: number | null;
  reverseHttpPort: number | null;
  sshPublicKeyRegistered: boolean;
  reverseSshSessionState: string;
  proxyMode: DeviceProxyMode;
  routingScheme: DeviceRoutingScheme;
  nameSource: "auto" | "admin";
  codeCleared: boolean;
  lastUpgrade: Record<string, unknown> | null;
  online: boolean;
  managementState: "online" | "offline";
  serviceState: "active" | "suspended" | "unbound" | "degraded" | "unknown";
  serviceReason: string | null;
  lineEnabled: boolean | null;
  lastSeenAt: string | null;
  agentVersion: string | null;
  createdAt: string;
};

export type ClientDeviceDetail = ClientDeviceListItem & {
  metrics: ClientDeviceMetrics | null;
  lineName: string | null;
  lineCountry: string | null;
  nodeName: string | null;
  sshConnectUrl: string | null;
  webRemoteUrl: string | null;
  flashRemoteUrl: string | null;
};

export type ClientDeviceMetrics = {
  cpuPercent?: number;
  cpuCores?: number;
  memoryUsedMb?: number;
  memoryTotalMb?: number;
  memoryPercent?: number;
  connectionCount?: number;
  uploadMbps?: number;
  downloadMbps?: number;
  uploadPeakMbps?: number;
  downloadPeakMbps?: number;
  updatedAt?: string;
};

export function normalizeClientDeviceMetrics(
  raw: Record<string, unknown> | null | undefined
): ClientDeviceMetrics | null {
  if (!raw || typeof raw !== "object") return null;

  const system = raw.system as Record<string, unknown> | undefined;
  const memory = system?.memory as Record<string, unknown> | undefined;
  const tunnel = raw.tunnel_traffic as Record<string, unknown> | undefined;

  const cpuPercent =
    (raw.cpu_percent as number | undefined) ??
    (raw.cpuPercent as number | undefined) ??
    (system?.cpu_percent as number | undefined);

  let memoryUsedMb = raw.memory_used_mb as number | undefined;
  let memoryTotalMb = raw.memory_total_mb as number | undefined;
  let memoryPercent = raw.memory_percent as number | undefined;

  if (memory) {
    const usedBytes = memory.used_bytes as number | undefined;
    const totalBytes = memory.total_bytes as number | undefined;
    if (usedBytes != null) memoryUsedMb = Math.round(usedBytes / 1024 / 1024);
    if (totalBytes != null) memoryTotalMb = Math.round(totalBytes / 1024 / 1024);
    if (memory.used_percent != null) memoryPercent = memory.used_percent as number;
  }

  let connectionCount =
    (raw.connection_count as number | undefined) ??
    (raw.connectionCount as number | undefined);
  if (connectionCount == null && tunnel?.active_conns != null) {
    connectionCount = Number(tunnel.active_conns);
  }

  let uploadMbps = raw.upload_mbps as number | undefined;
  let downloadMbps = raw.download_mbps as number | undefined;
  if (tunnel) {
    const windowSec = Number(tunnel.window_seconds) || 1;
    const bytesIn = Number(tunnel.bytes_in) || 0;
    const bytesOut = Number(tunnel.bytes_out) || 0;
    if (uploadMbps == null && bytesOut > 0) {
      uploadMbps = (bytesOut * 8) / windowSec / 1_000_000;
    }
    if (downloadMbps == null && bytesIn > 0) {
      downloadMbps = (bytesIn * 8) / windowSec / 1_000_000;
    }
  }

  return {
    cpuPercent,
    cpuCores: (raw.cpu_cores as number | undefined) ?? (system?.cpu_cores as number | undefined),
    memoryUsedMb,
    memoryTotalMb,
    memoryPercent,
    connectionCount,
    uploadMbps,
    downloadMbps,
    uploadPeakMbps: raw.upload_peak_mbps as number | undefined,
    downloadPeakMbps: raw.download_peak_mbps as number | undefined,
    updatedAt: (raw.ts as string | undefined) ?? (raw.updated_at as string | undefined),
  };
}

export function lineBindingLabel(
  tid: string | null | undefined,
  nodeName: string | null | undefined,
  country: string | null | undefined
): string {
  if (!tid) return "未绑线";
  const parts = [tid, nodeName, country].filter(Boolean);
  return parts.join(" · ");
}

export type StaticRoute = {
  prefix: string;
  next_hop?: string | null;
  device?: string | null;
  comment?: string | null;
};

export type SocksProfile = {
  id: number;
  name: string;
  host: string;
  port: number;
  username: string | null;
  password: string | null;
  country: string | null;
  channel: string | null;
  remark: string | null;
  addressDisplay: string;
  isHealthy: boolean;
  lineBindingCount: number;
  createdAt: string | null;
};

export type AlertEvent = {
  id: number;
  nodeId: number | null;
  lineId: number | null;
  level: string;
  type: string;
  message: string;
  createdAt: string;
};

export type FlowStat = {
  id: number;
  nodeId: number;
  lineId: number | null;
  windowStart: string;
  windowSeconds: number;
  bytesIn: number;
  bytesOut: number;
  activeConns: number;
};

export type NodeTrafficOverview = {
  nodeId: number;
  nodeName: string;
  country: string | null;
  publicIp: string | null;
  online: boolean;
  last24hBytes: number;
  recentIncrementBytes: number;
  billingPeriodBytes: number;
  billingCycleStartAt: string | null;
  billingCycleEndAt: string | null;
  billingCycleDays: number;
  monthlyQuotaGb: number | null;
  quotaUsedPercent: number | null;
  correctionBytes: number;
  monitorIface: string | null;
  status: string;
  lastSampleAt: string | null;
};

export function mapNodeTrafficOverview(raw: Record<string, unknown>): NodeTrafficOverview {
  return {
    nodeId: raw.node_id as number,
    nodeName: raw.node_name as string,
    country: (raw.country as string | null) ?? null,
    publicIp: (raw.public_ip as string | null) ?? null,
    online: raw.online as boolean,
    last24hBytes: raw.last_24h_bytes as number,
    recentIncrementBytes: raw.recent_increment_bytes as number,
    billingPeriodBytes: raw.billing_period_bytes as number,
    billingCycleStartAt: (raw.billing_cycle_start_at as string | null) ?? null,
    billingCycleEndAt: (raw.billing_cycle_end_at as string | null) ?? null,
    billingCycleDays: raw.billing_cycle_days as number,
    monthlyQuotaGb: (raw.monthly_quota_gb as number | null) ?? null,
    quotaUsedPercent: (raw.quota_used_percent as number | null) ?? null,
    correctionBytes: raw.correction_bytes as number,
    monitorIface: (raw.monitor_iface as string | null) ?? null,
    status: raw.status as string,
    lastSampleAt: (raw.last_sample_at as string | null) ?? null,
  };
}

export type PlatformUser = {
  id: number;
  username: string;
  role: string;
  isActive: boolean;
  createdAt: string;
};

export type OperationLog = {
  id: number;
  username: string;
  action: string;
  target: string;
  detail: string | null;
  createdAt: string;
};

/** API returns snake_case; map to camelCase for UI */
export function mapLineItem(raw: Record<string, unknown>): LineListItem {
  return {
    id: raw.id as number,
    tid: raw.tid as string,
    name: raw.name as string,
    nodeId: raw.node_id as number,
    nodeName: raw.node_name as string,
    country: raw.country as string,
    bandwidthMbps: raw.bandwidth_mbps as number,
    remark: raw.remark as string | null,
    isEnabled: raw.is_enabled as boolean,
    status: raw.status as string,
    createdAt: raw.created_at as string,
    socksProfileId: (raw.socks_profile_id as number | null) ?? null,
    socksName: (raw.socks_name as string | null) ?? null,
    lineType: (raw.line_type as string) || "client",
    clientDeviceId: (raw.client_device_id as number | null) ?? null,
    clientDeviceName: (raw.client_device_name as string | null) ?? null,
  };
}

export function mapLineDetail(raw: Record<string, unknown>): LineDetail {
  const base = mapLineItem(raw);
  return {
    ...base,
    sourceCidrs: raw.source_cidrs as string[],
    socksRemark: raw.socks_remark as string | null,
    createdBy: raw.created_by as string,
    socksHost: (raw.socks_host as string | null) ?? null,
    socksPort: (raw.socks_port as number | null) ?? null,
    socksUsername: raw.socks_username as string | null,
    socksPassword: raw.socks_password as string | null,
    clientSocksDisplay: (raw.client_socks_display as string) || "N/A",
    currentConfigVersion: raw.current_config_version as string | null,
    clientUuid: (raw.client_uuid as string | null) ?? null,
    lineCodeB32: (raw.line_code_b32 as string | null) ?? null,
    flowStatsEnabled: raw.flow_stats_enabled !== false,
    socksUdpOverTcp: raw.socks_udp_over_tcp !== false,
  };
}

export function mapClientDevice(raw: Record<string, unknown>): ClientDeviceListItem {
  return {
    id: raw.id as number,
    name: raw.name as string,
    deviceKey: raw.device_key as string,
    lanMac: (raw.lan_mac as string | null) ?? null,
    deviceId: (raw.device_id as string | null) ?? null,
    lineId: (raw.line_id as number | null) ?? null,
    lineTid: (raw.line_tid as string | null) ?? null,
    reverseSshPort: (raw.reverse_ssh_port as number | null) ?? null,
    reverseHttpPort: (raw.reverse_http_port as number | null) ?? null,
    sshPublicKeyRegistered: Boolean(raw.ssh_public_key_registered),
    reverseSshSessionState: String(raw.reverse_ssh_session_state || "idle"),
    proxyMode: ((raw.proxy_mode as string) || "gateway") as DeviceProxyMode,
    routingScheme: ((raw.routing_scheme as string) || "split") as DeviceRoutingScheme,
    nameSource: ((raw.name_source as string) || "auto") === "admin" ? "admin" : "auto",
    codeCleared: Boolean(raw.code_cleared),
    lastUpgrade: (raw.last_upgrade as Record<string, unknown> | null) ?? null,
    online: raw.online as boolean,
    managementState: (raw.management_state as ClientDeviceListItem["managementState"]) || (raw.online ? "online" : "offline"),
    serviceState: (raw.service_state as ClientDeviceListItem["serviceState"]) || "unknown",
    serviceReason: (raw.service_reason as string | null) ?? null,
    lineEnabled: (raw.line_enabled as boolean | null) ?? null,
    lastSeenAt: (raw.last_seen_at as string | null) ?? null,
    agentVersion: (raw.agent_version as string | null) ?? null,
    createdAt: raw.created_at as string,
  };
}

export function mapClientDeviceDetail(raw: Record<string, unknown>): ClientDeviceDetail {
  const base = mapClientDevice(raw);
  const rawMetrics = raw.metrics as Record<string, unknown> | null | undefined;
  return {
    ...base,
    metrics: normalizeClientDeviceMetrics(rawMetrics),
    lineName: (raw.line_name as string | null) ?? null,
    lineCountry: (raw.line_country as string | null) ?? null,
    nodeName: (raw.node_name as string | null) ?? null,
    sshConnectUrl: (raw.ssh_connect_url as string | null) ?? null,
    webRemoteUrl: (raw.web_remote_url as string | null) ?? null,
    flashRemoteUrl: (raw.flash_remote_url as string | null) ?? null,
  };
}

export function mapNode(raw: Record<string, unknown>): NodeRow {
  return {
    id: raw.id as number,
    nodeKey: (raw.nodeKey as string) || "",
    name: raw.name as string,
    region: raw.region as string,
    country: (raw.country as string) || raw.region as string,
    publicIp: (raw.publicIp as string) || null,
    isActive: raw.isActive as boolean,
    online: raw.online as boolean,
    lastSeenAt: (raw.lastSeenAt as string) || null,
    currentConfigVersion: (raw.currentConfigVersion as string) || null,
    createdAt: (raw.createdAt as string) || null,
    monthlyQuotaGb: (raw.monthlyQuotaGb as number | null) ?? null,
    quotaUsedPercent: (raw.quotaUsedPercent as number | null) ?? null,
  };
}

export function quotaPercentInt(percent: number | null | undefined): number | null {
  if (percent == null) return null;
  return Math.round(percent);
}

export function trafficUsageTagColor(
  percent: number | null,
  hasQuota: boolean
): "default" | "green" | "orange" | "red" {
  if (!hasQuota) return "default";
  if (percent == null) return "default";
  if (percent >= 95) return "red";
  if (percent >= 85) return "orange";
  return "green";
}

export function trafficUsageLabel(node: Pick<NodeRow, "monthlyQuotaGb" | "quotaUsedPercent">): string {
  if (!node.monthlyQuotaGb) return "无限制";
  const pct = quotaPercentInt(node.quotaUsedPercent);
  return pct == null ? "—" : `${pct}%`;
}

export function nodeOptionLabel(n: NodeRow): string {
  const ip = n.publicIp ? ` ${n.publicIp}` : "";
  const st = n.online ? "在线" : "离线";
  let traffic = "";
  if (n.monthlyQuotaGb) {
    const pct = quotaPercentInt(n.quotaUsedPercent);
    if (pct != null) {
      const warn = pct >= 95 ? " ⚠⚠" : pct >= 85 ? " ⚠" : "";
      traffic = ` · 流量 ${pct}%${warn}`;
    }
  } else {
    traffic = " · 无限制";
  }
  return `#${n.id} ${n.name} (${n.region})${ip} [${st}]${traffic}`;
}

export function mapDashboard(raw: Record<string, unknown>): Dashboard {
  return {
    nodeTotal: raw.node_total as number,
    nodeOnline: raw.node_online as number,
    lineTotal: raw.line_total as number,
    lineActive: raw.line_active as number,
    socksTotal: raw.socks_total as number,
    socksOnline: (raw.socks_online as number) ?? 0,
    socksOffline: (raw.socks_offline as number) ?? 0,
    alertOpen: raw.alert_open as number,
    socksAlertOpen: (raw.socks_alert_open as number) ?? 0,
  };
}

export function alertCategory(type: string): "socks" | "node" | "other" {
  if (type.startsWith("socks_down_")) return "socks";
  if (
    type.startsWith("service_down_") ||
    type === "node_offline" ||
    type === "config_apply_failed" ||
    type.startsWith("traffic_quota_")
  ) {
    return "node";
  }
  return "other";
}

export function mapSocks(raw: Record<string, unknown>): SocksProfile {
  return {
    id: raw.id as number,
    name: raw.name as string,
    host: raw.host as string,
    port: raw.port as number,
    username: raw.username as string | null,
    password: raw.password as string | null,
    country: (raw.country as string) || null,
    channel: (raw.channel as string) || null,
    remark: raw.remark as string | null,
    addressDisplay: (raw.address_display as string) || "",
    isHealthy: raw.is_healthy as boolean,
    lineBindingCount: (raw.line_binding_count as number) ?? 0,
    createdAt: raw.created_at as string | null,
  };
}
