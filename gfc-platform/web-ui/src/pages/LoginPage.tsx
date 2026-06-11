import { Alert, Button, Card, Form, Input, Typography, message } from "antd";
import { useEffect, useState } from "react";
import { useNavigate } from "react-router-dom";
import { mapUser, setAuth } from "../api/auth";
import { apiGet, apiPost } from "../api/client";

type SetupHint = {
  username: string;
  initial_password: string | null;
  password_change_required: boolean;
};

export function LoginPage() {
  const nav = useNavigate();
  const [form] = Form.useForm();
  const [hint, setHint] = useState<SetupHint | null>(null);

  useEffect(() => {
    void apiGet<SetupHint>("/auth/setup-hint")
      .then(setHint)
      .catch(() => setHint(null));
  }, []);

  return (
    <div
      style={{
        minHeight: "100vh",
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        background: "linear-gradient(135deg, #e6f4ff 0%, #f5f5f5 100%)",
      }}
    >
      <Card style={{ width: 440 }}>
        <Typography.Title level={3} style={{ marginTop: 0, textAlign: "center" }}>
          应用加速平台
        </Typography.Title>
        <Typography.Paragraph type="secondary" style={{ textAlign: "center" }}>
          请使用控制台账号登录
        </Typography.Paragraph>

        {hint?.password_change_required && hint.initial_password && (
          <Alert
            type="info"
            showIcon
            style={{ marginBottom: 16 }}
            message="首次部署 — 初始管理员账号"
            description={
              <div>
                <div>
                  用户名：<Typography.Text strong>{hint.username}</Typography.Text>
                </div>
                <div style={{ marginTop: 8 }}>
                  初始密码：
                  <Typography.Text copyable code>
                    {hint.initial_password}
                  </Typography.Text>
                </div>
                <div style={{ marginTop: 8, fontSize: 12 }}>
                  登录后须立即修改密码方可进入系统。也可在服务器执行：
                  <Typography.Text code style={{ fontSize: 11 }}>
                    docker-compose logs api | grep &quot;GFC] Security&quot;
                  </Typography.Text>
                </div>
              </div>
            }
          />
        )}

        <Form
          form={form}
          layout="vertical"
          initialValues={{ username: "admin" }}
          onFinish={async (v) => {
            try {
              const res = await apiPost<{
                token: string;
                user: Record<string, unknown>;
                must_change_password: boolean;
              }>("/auth/login", { username: v.username, password: v.password });
              setAuth(res.token, {
                ...mapUser(res.user),
                mustChangePassword: res.must_change_password,
              });
              message.success("登录成功");
              if (res.must_change_password) {
                nav("/change-password", { replace: true });
              } else {
                nav("/", { replace: true });
              }
            } catch (e) {
              message.error(String(e));
            }
          }}
        >
          <Form.Item name="username" label="用户名" rules={[{ required: true }]}>
            <Input autoComplete="username" />
          </Form.Item>
          <Form.Item name="password" label="密码" rules={[{ required: true }]}>
            <Input.Password autoComplete="current-password" />
          </Form.Item>
          <Button type="primary" htmlType="submit" block>
            登录
          </Button>
        </Form>
      </Card>
    </div>
  );
}
