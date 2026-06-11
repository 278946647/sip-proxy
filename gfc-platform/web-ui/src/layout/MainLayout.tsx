import {
  DashboardOutlined,
  LineChartOutlined,
  HeartOutlined,
  CloudServerOutlined,
  ClusterOutlined,
  UserOutlined,
  FileTextOutlined,
  QuestionCircleOutlined,
  LogoutOutlined,
  GlobalOutlined,
  MobileOutlined,
  SettingOutlined,
  KeyOutlined,
} from "@ant-design/icons";
import { Layout, Menu, Tag, Button, Space, theme, Modal, Form, Input, message, Dropdown } from "antd";
import { Outlet, useLocation, useNavigate } from "react-router-dom";
import { useState } from "react";
import { clearAuth, getUser } from "../api/auth";
import { apiPost } from "../api/client";

const { Header, Sider, Content } = Layout;

const menuItems = [
  { key: "/", icon: <DashboardOutlined />, label: "仪表盘" },
  { key: "/nodes", icon: <ClusterOutlined />, label: "转发节点" },
  { key: "/lines", icon: <GlobalOutlined />, label: "线路管理" },
  { key: "/client-devices", icon: <MobileOutlined />, label: "客户端管理" },
  { key: "/traffic", icon: <LineChartOutlined />, label: "流量" },
  { key: "/health", icon: <HeartOutlined />, label: "健康检查" },
  { key: "/proxies", icon: <CloudServerOutlined />, label: "代理配置" },
  { key: "/settings", icon: <SettingOutlined />, label: "系统设置" },
  { key: "/users", icon: <UserOutlined />, label: "用户管理" },
  { key: "/logs", icon: <FileTextOutlined />, label: "操作日志" },
  { key: "/help", icon: <QuestionCircleOutlined />, label: "使用说明" },
];

export function MainLayout() {
  const nav = useNavigate();
  const loc = useLocation();
  const { token } = theme.useToken();
  const user = getUser();
  const [pwdOpen, setPwdOpen] = useState(false);
  const [pwdForm] = Form.useForm();

  const selected = menuItems.find((m) =>
    m.key === "/" ? loc.pathname === "/" : loc.pathname.startsWith(m.key)
  )?.key ?? "/lines";

  const logout = () => {
    clearAuth();
    void apiPost("/auth/logout", {}).catch(() => undefined);
    nav("/login", { replace: true });
  };

  return (
    <Layout style={{ minHeight: "100vh" }}>
      <Sider width={220} theme="dark">
        <div className="gfc-logo">
          <GlobalOutlined style={{ marginRight: 8 }} />
          应用加速平台
        </div>
        <Menu
          theme="dark"
          mode="inline"
          selectedKeys={[selected]}
          items={menuItems}
          onClick={({ key }) => nav(key)}
        />
      </Sider>
      <Layout>
        <Header
          style={{
            background: token.colorBgContainer,
            padding: "0 24px",
            display: "flex",
            alignItems: "center",
            justifyContent: "flex-end",
            borderBottom: `1px solid ${token.colorBorderSecondary}`,
          }}
        >
          <Dropdown
            menu={{
              items: [
                {
                  key: "password",
                  icon: <KeyOutlined />,
                  label: "修改密码",
                  onClick: () => setPwdOpen(true),
                },
                {
                  key: "logout",
                  icon: <LogoutOutlined />,
                  label: "退出登录",
                  onClick: logout,
                },
              ],
            }}
          >
            <Space style={{ cursor: "pointer" }}>
              <span>{user?.username || "用户"}</span>
              <Tag>{user?.role || "-"}</Tag>
            </Space>
          </Dropdown>
        </Header>
        <Content style={{ margin: 24, minHeight: 280 }}>
          <Outlet />
        </Content>
      </Layout>

      <Modal
        title="修改密码"
        open={pwdOpen}
        onCancel={() => setPwdOpen(false)}
        onOk={async () => {
          const v = await pwdForm.validateFields();
          try {
            await apiPost("/auth/change-password", {
              old_password: v.oldPassword,
              new_password: v.newPassword,
            });
            message.success("密码已修改，请重新登录");
            setPwdOpen(false);
            logout();
          } catch (e) {
            message.error(String(e));
          }
        }}
      >
        <Form form={pwdForm} layout="vertical">
          <Form.Item name="oldPassword" label="当前密码" rules={[{ required: true }]}>
            <Input.Password />
          </Form.Item>
          <Form.Item
            name="newPassword"
            label="新密码"
            rules={[{ required: true, min: 6, message: "至少 6 位" }]}
          >
            <Input.Password />
          </Form.Item>
          <Form.Item
            name="confirm"
            label="确认新密码"
            dependencies={["newPassword"]}
            rules={[
              { required: true },
              ({ getFieldValue }) => ({
                validator(_, value) {
                  if (!value || getFieldValue("newPassword") === value) return Promise.resolve();
                  return Promise.reject(new Error("两次密码不一致"));
                },
              }),
            ]}
          >
            <Input.Password />
          </Form.Item>
        </Form>
      </Modal>
    </Layout>
  );
}
