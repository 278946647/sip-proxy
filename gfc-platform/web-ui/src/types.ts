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
};

export type ClientDeviceListItem = {
  id: number;
  name: string;
  deviceKey: string;
  lanMac: string | null;
  deviceId: string | null;
  lineId: number | null;
  lineTid: string | null;
  reverseSshPort: number | null;
  proxyMode: string;
  online: boolean;
  lastSeenAt: string | null;
  agentVersion: string | null;
  createdAt: string;
};

export type ClientDeviceDetail = ClientDeviceListItem & {
  metrics: ClientDeviceMetrics | null;
  lineName: string | null;
  nodeName: string | null;
  sshConnectUrl: string | null;
};

export type ClientDeviceMetrics = {
  cpuPercent?: number;
  cpuCores?: number;
  memoryUsedMb?: number;
  memoryTotalMb?: number;
  connectionCount?: number;
  uploadMbps?: number;
  downloadMbps?: number;
  uploadPeakMbps?: number;
  downloadPeakMbps?: number;
};

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
    proxyMode: (raw.proxy_mode as string) || "gateway",
    online: raw.online as boolean,
    lastSeenAt: (raw.last_seen_at as string | null) ?? null,
    agentVersion: (raw.agent_version as string | null) ?? null,
    createdAt: raw.created_at as string,
  };
}

export function mapClientDeviceDetail(raw: Record<string, unknown>): ClientDeviceDetail {
  const base = mapClientDevice(raw);
  return {
    ...base,
    metrics: (raw.metrics as ClientDeviceMetrics | null) ?? null,
    lineName: (raw.line_name as string | null) ?? null,
    nodeName: (raw.node_name as string | null) ?? null,
    sshConnectUrl: (raw.ssh_connect_url as string | null) ?? null,
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
  };
}

export function nodeOptionLabel(n: NodeRow): string {
  const ip = n.publicIp ? ` ${n.publicIp}` : "";
  const st = n.online ? "在线" : "离线";
  return `#${n.id} ${n.name} (${n.region})${ip} [${st}]`;
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
  if (type.startsWith("service_down_") || type === "node_offline" || type === "config_apply_failed") {
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
    createdAt: raw.created_at as string | null,
  };
}
