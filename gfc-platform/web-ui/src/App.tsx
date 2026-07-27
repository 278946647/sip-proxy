import { ConfigProvider } from "antd";
import zhCN from "antd/locale/zh_CN";
import { BrowserRouter, Navigate, Route, Routes } from "react-router-dom";
import { RequireAuth } from "./components/RequireAuth";
import { RequirePasswordChange } from "./components/RequirePasswordChange";
import { MainLayout } from "./layout/MainLayout";
import { DashboardPage } from "./pages/DashboardPage";
import { LiveCatalogPage } from "./pages/LiveCatalogPage";
import { ClientDevicesPage } from "./pages/ClientDevicesPage";
import { ClientDeviceDetailPage } from "./pages/ClientDeviceDetailPage";
import { ClientWebSSHPage } from "./pages/ClientWebSSHPage";
import { LineDetailPage } from "./pages/LineDetailPage";
import { LinesPage } from "./pages/LinesPage";
import { TrafficPage } from "./pages/TrafficPage";
import { HealthPage } from "./pages/HealthPage";
import { NodesPage } from "./pages/NodesPage";
import { ProxiesPage } from "./pages/ProxiesPage";
import { UsersPage } from "./pages/UsersPage";
import { LogsPage } from "./pages/LogsPage";
import { HelpPage } from "./pages/HelpPage";
import { InitialPasswordPage } from "./pages/InitialPasswordPage";
import { LoginPage } from "./pages/LoginPage";
import { SettingsPage } from "./pages/SettingsPage";
import { SettingsSecurityPage } from "./pages/SettingsSecurityPage";
import { SettingsEmailPage } from "./pages/SettingsEmailPage";
import { SettingsArtifactsPage } from "./pages/SettingsArtifactsPage";
import { getToken } from "./api/auth";
import "antd/dist/reset.css";
import "./styles/global.css";

export function App() {
  return (
    <ConfigProvider
      locale={zhCN}
      theme={{
        token: {
          colorPrimary: "#1677ff",
          borderRadius: 8,
        },
      }}
    >
      <BrowserRouter>
        <Routes>
          <Route path="/login" element={getToken() ? <Navigate to="/" replace /> : <LoginPage />} />
          <Route element={<RequireAuth />}>
            <Route path="/change-password" element={<InitialPasswordPage />} />
            <Route path="client-devices/:id/ssh" element={<ClientWebSSHPage />} />
            <Route element={<RequirePasswordChange />}>
            <Route path="/" element={<MainLayout />}>
              <Route index element={<DashboardPage />} />
              <Route path="nodes" element={<NodesPage />} />
              <Route path="lines" element={<LinesPage />} />
              <Route path="lines/:id" element={<LineDetailPage />} />
              <Route path="live-catalog" element={<LiveCatalogPage />} />
              <Route path="client-devices" element={<ClientDevicesPage />} />
              <Route path="client-devices/:id" element={<ClientDeviceDetailPage />} />
              <Route path="traffic" element={<TrafficPage />} />
              <Route path="health" element={<HealthPage />} />
              <Route path="proxies" element={<ProxiesPage />} />
              <Route path="users" element={<UsersPage />} />
              <Route path="settings" element={<SettingsPage />} />
              <Route path="settings/security" element={<SettingsSecurityPage />} />
              <Route path="settings/email" element={<SettingsEmailPage />} />
              <Route path="settings/artifacts" element={<SettingsArtifactsPage />} />
              <Route path="logs" element={<LogsPage />} />
              <Route path="help" element={<HelpPage />} />
              <Route path="*" element={<Navigate to="/lines" replace />} />
            </Route>
            </Route>
          </Route>
        </Routes>
      </BrowserRouter>
    </ConfigProvider>
  );
}
