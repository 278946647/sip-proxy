import { apiGet, apiPost } from "../api/client";

export type ReverseSSHSession = {
  state: string;
  expiresAt: string | null;
  tunnelReady: boolean;
  ports: { ssh: number | null; http: number | null } | null;
  targets: string[];
  urls: Record<string, string | null>;
  message: string | null;
};

function mapSession(raw: Record<string, unknown>): ReverseSSHSession {
  const ports = raw.ports as Record<string, unknown> | null | undefined;
  return {
    state: String(raw.state || "idle"),
    expiresAt: (raw.expires_at as string | null) ?? null,
    tunnelReady: Boolean(raw.tunnel_ready),
    ports: ports
      ? { ssh: (ports.ssh as number | null) ?? null, http: (ports.http as number | null) ?? null }
      : null,
    targets: (raw.targets as string[]) || [],
    urls: (raw.urls as Record<string, string | null>) || {},
    message: (raw.message as string | null) ?? null,
  };
}

export async function startReverseSession(
  deviceId: number,
  targets: string[]
): Promise<ReverseSSHSession> {
  const raw = await apiPost<Record<string, unknown>>(
    `/admin/client-devices/${deviceId}/reverse-ssh/session?operator=${
      localStorage.getItem("gfc_user") || "admin"
    }`,
    { targets }
  );
  return mapSession(raw);
}

export async function getReverseSession(deviceId: number): Promise<ReverseSSHSession> {
  const raw = await apiGet<Record<string, unknown>>(
    `/admin/client-devices/${deviceId}/reverse-ssh/session`
  );
  return mapSession(raw);
}

export async function waitForTunnel(
  deviceId: number,
  timeoutMs = 90000,
  intervalMs = 3000
): Promise<ReverseSSHSession> {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    const session = await getReverseSession(deviceId);
    if (session.tunnelReady) return session;
    if (session.state === "idle" || session.state === "failed") {
      throw new Error(session.message || "远程隧道建立失败");
    }
    await new Promise((r) => window.setTimeout(r, intervalMs));
  }
  throw new Error("等待设备建连超时");
}

export function websshUrl(deviceId: number): string {
  const token = localStorage.getItem("gfc_token") || "";
  const proto = window.location.protocol === "https:" ? "wss:" : "ws:";
  const base = `${proto}//${window.location.host}`;
  return `${base}/api/admin/ws/ssh/${deviceId}?token=${encodeURIComponent(token)}`;
}
