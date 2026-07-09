export type UserPermissions = {
  actions: string[];
  menus: string[];
  canRemoteAccess: boolean;
  canDeleteStructural: boolean;
  canWriteTrafficBilling: boolean;
};

export type AuthUser = {
  id: number;
  username: string;
  role: string;
  isActive: boolean;
  createdAt: string;
  mustChangePassword?: boolean;
  permissions?: UserPermissions;
};

const TOKEN_KEY = "gfc_token";
const USER_KEY = "gfc_user";

export function getToken(): string | null {
  return localStorage.getItem(TOKEN_KEY);
}

export function getUser(): AuthUser | null {
  const raw = localStorage.getItem(USER_KEY);
  if (!raw) return null;
  try {
    return JSON.parse(raw) as AuthUser;
  } catch {
    return null;
  }
}

export function setAuth(token: string, user: AuthUser) {
  localStorage.setItem(TOKEN_KEY, token);
  localStorage.setItem(USER_KEY, JSON.stringify(user));
}

export function clearAuth() {
  localStorage.removeItem(TOKEN_KEY);
  localStorage.removeItem(USER_KEY);
}

export function mapUser(
  raw: Record<string, unknown>,
  mustChangePassword = false
): AuthUser {
  const perms = raw.permissions as Record<string, unknown> | undefined;
  return {
    id: raw.id as number,
    username: raw.username as string,
    role: raw.role as string,
    isActive: raw.is_active as boolean,
    createdAt: raw.created_at as string,
    mustChangePassword,
    permissions: perms
      ? {
          actions: (perms.actions as string[]) ?? [],
          menus: (perms.menus as string[]) ?? [],
          canRemoteAccess: Boolean(perms.can_remote_access),
          canDeleteStructural: Boolean(perms.can_delete_structural),
          canWriteTrafficBilling: Boolean(perms.can_write_traffic_billing),
        }
      : undefined,
  };
}
