const ADDR_RE =
  /^(?:(?<username>[^:]+):(?<password>[^@]+)@)?(?<host>\d{1,3}(?:\.\d{1,3}){3}|[a-zA-Z0-9.-]+):(?<port>\d{1,5})$/;

export function parseSocksAddress(address: string): {
  host: string;
  port: number;
  username: string | null;
  password: string | null;
} {
  const raw = address.trim();
  const m = ADDR_RE.exec(raw);
  if (!m?.groups?.host || !m.groups.port) {
    throw new Error("格式应为 username:password@IP:Port（无认证时可写 host:port）");
  }
  const port = Number(m.groups.port);
  if (port < 1 || port > 65535) throw new Error("端口须在 1-65535");
  return {
    host: m.groups.host,
    port,
    username: m.groups.username ?? null,
    password: m.groups.password ?? null,
  };
}

export function formatSocksAddress(
  host: string,
  port: number,
  username: string | null,
  password: string | null
): string {
  if (username) return `${username}:${password ?? ""}@${host}:${port}`;
  return `${host}:${port}`;
}
