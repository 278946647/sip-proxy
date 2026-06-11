export type AuthUser = {
  id: number;
  username: string;
  role: string;
  isActive: boolean;
  createdAt: string;
  mustChangePassword?: boolean;
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
  return {
    id: raw.id as number,
    username: raw.username as string,
    role: raw.role as string,
    isActive: raw.is_active as boolean,
    createdAt: raw.created_at as string,
    mustChangePassword,
  };
}
