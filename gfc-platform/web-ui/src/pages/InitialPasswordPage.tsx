import { Alert, Button, Card, Form, Input, Typography, message } from "antd";
import { mapUser, setAuth } from "../api/auth";
import { apiPost } from "../api/client";

export function InitialPasswordPage() {
  const [form] = Form.useForm();

  return (
    <div
      style={{
        minHeight: "100vh",
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        background: "linear-gradient(135deg, #fff7e6 0%, #f5f5f5 100%)",
      }}
    >
      <Card style={{ width: 420 }}>
        <Typography.Title level={4} style={{ marginTop: 0 }}>
          首次登录 — 请修改管理员密码
        </Typography.Title>
        <Alert
          type="warning"
          showIcon
          style={{ marginBottom: 16 }}
          message="安全要求"
          description="初始密码仅用于首次登录。请设置新的强密码后才能进入系统。"
        />
        <Form
          form={form}
          layout="vertical"
          onFinish={async (v) => {
            if (v.newPassword !== v.confirmPassword) {
              message.error("两次输入的密码不一致");
              return;
            }
            try {
              const res = await apiPost<{
                token: string;
                user: Record<string, unknown>;
                must_change_password: boolean;
              }>("/auth/initial-password-change", {
                new_password: v.newPassword,
                confirm_password: v.confirmPassword,
              });
              setAuth(res.token, {
                ...mapUser(res.user),
                mustChangePassword: res.must_change_password,
              });
              message.success("密码已更新，欢迎使用");
              window.location.href = "/";
            } catch (e) {
              message.error(String(e));
            }
          }}
        >
          <Form.Item
            name="newPassword"
            label="新密码"
            rules={[{ required: true, min: 8, message: "至少 8 位" }]}
          >
            <Input.Password autoComplete="new-password" />
          </Form.Item>
          <Form.Item
            name="confirmPassword"
            label="确认新密码"
            rules={[{ required: true, min: 8 }]}
          >
            <Input.Password autoComplete="new-password" />
          </Form.Item>
          <Button type="primary" htmlType="submit" block>
            保存并进入系统
          </Button>
        </Form>
      </Card>
    </div>
  );
}
