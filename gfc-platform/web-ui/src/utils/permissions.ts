import type { AuthUser } from "../api/auth";

export type UserPermissions = {
  actions: string[];
  menus: string[];
  canRemoteAccess: boolean;
  canDeleteStructural: boolean;
  canWriteTrafficBilling: boolean;
};

export function permissionsFromUser(user: AuthUser | null): UserPermissions {
  const p = user?.permissions;
  return {
    actions: p?.actions ?? [],
    menus: p?.menus ?? [],
    canRemoteAccess: p?.canRemoteAccess ?? false,
    canDeleteStructural: p?.canDeleteStructural ?? user?.role === "admin",
    canWriteTrafficBilling: p?.canWriteTrafficBilling ?? user?.role === "admin",
  };
}

export function isAdmin(user: AuthUser | null): boolean {
  return user?.role === "admin";
}

export function isAuditor(user: AuthUser | null): boolean {
  return user?.role === "auditor";
}

export function canWrite(user: AuthUser | null): boolean {
  if (!user) return false;
  if (isAuditor(user)) return false;
  return true;
}

export function canMenu(user: AuthUser | null, key: string): boolean {
  const menus = permissionsFromUser(user).menus;
  return menus.includes(key);
}

export function isOperatorDeletableClient(row: {
  online: boolean;
  lineId: number | null;
  reverseSshSessionState: string;
}): boolean {
  return !row.online && row.lineId == null && row.reverseSshSessionState === "idle";
}

export function roleLabel(role: string): string {
  if (role === "admin") return "超级管理员";
  if (role === "operator") return "运维";
  if (role === "auditor") return "审计";
  return role;
}
