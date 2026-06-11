import { Navigate, Outlet, useLocation } from "react-router-dom";
import { getUser } from "../api/auth";

export function RequirePasswordChange() {
  const loc = useLocation();
  const user = getUser();
  if (user?.mustChangePassword && loc.pathname !== "/change-password") {
    return <Navigate to="/change-password" replace />;
  }
  if (!user?.mustChangePassword && loc.pathname === "/change-password") {
    return <Navigate to="/" replace />;
  }
  return <Outlet />;
}
