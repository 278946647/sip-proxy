import { ArrowLeftOutlined } from "@ant-design/icons";
import {
  Button,
  Card,
  Form,
  Input,
  InputNumber,
  Space,
  Switch,
  Typography,
  message,
} from "antd";
import { useEffect, useState } from "react";
import { useNavigate } from "react-router-dom";
import { apiGet, apiPost, apiPut } from "../api/client";

type EmailSettings = {
  configured: boolean;
  source: string;
  host?: string;
  port?: number;
  username?: string | null;
  passwordSet?: boolean;
  mailFrom?: string;
  mailTo?: string;
  starttls?: boolean;
};

export function SettingsEmailPage() {
  const nav = useNavigate();
  const [form] = Form.useForm();
  const [loading, setLoading] = useState(false);
  const [meta, setMeta] = useState<EmailSettings | null>(null);

  const load = async () => {
    const s = await apiGet<EmailSettings>("/admin/settings/email");
    setMeta(s);
    form.setFieldsValue({
      host: s.host || "",
      port: s.port || 587,
      username: s.username || "",
      mailFrom: s.mailFrom || "",
      mailTo: s.mailTo || "",
      starttls: s.starttls ?? true,
    });
  };

  useEffect(() => {
    void load().catch((e) => message.error(String(e)));
  }, [form]);

  return (
    <div>
      <Space style={{ marginBottom: 16 }}>
        <Button icon={<ArrowLeftOutlined />} onClick={() => nav("/settings")}>
          返回系统设置
        </Button>
      </Space>
      <Typography.Title level={4}>邮件告警</Typography.Title>
      <Card>
        <Typography.Paragraph type="secondary">
          用于节点离线、服务异常、SOCKS 不可用等告警邮件。保存后写入控制平台数据库；若未配置则回退到环境变量
          GFC_SMTP_*。
          {meta?.configured && (
            <>
              {" "}
              当前来源：<strong>{meta.source === "env" ? "环境变量" : "控制台配置"}</strong>
            </>
          )}
        </Typography.Paragraph>
        <Form form={form} layout="vertical" style={{ maxWidth: 520 }}>
          <Form.Item name="host" label="SMTP 主机" rules={[{ required: true }]}>
            <Input placeholder="smtp.example.com" />
          </Form.Item>
          <Form.Item name="port" label="端口" rules={[{ required: true }]}>
            <InputNumber min={1} max={65535} style={{ width: 120 }} />
          </Form.Item>
          <Form.Item name="username" label="用户名">
            <Input />
          </Form.Item>
          <Form.Item
            name="password"
            label="密码"
            extra={meta?.passwordSet ? "已保存密码；留空表示不修改" : undefined}
          >
            <Input.Password placeholder={meta?.passwordSet ? "留空不修改" : ""} />
          </Form.Item>
          <Form.Item name="mailFrom" label="发件人" rules={[{ required: true, type: "email" }]}>
            <Input placeholder="gfc@example.com" />
          </Form.Item>
          <Form.Item name="mailTo" label="收件人" rules={[{ required: true, type: "email" }]}>
            <Input placeholder="ops@example.com" />
          </Form.Item>
          <Form.Item name="starttls" label="STARTTLS" valuePropName="checked">
            <Switch />
          </Form.Item>
          <Button
            type="primary"
            loading={loading}
            onClick={async () => {
              const v = await form.validateFields();
              setLoading(true);
              try {
                await apiPut("/admin/settings/email", {
                  host: v.host,
                  port: v.port,
                  username: v.username || null,
                  password: v.password || null,
                  mail_from: v.mailFrom,
                  mail_to: v.mailTo,
                  starttls: v.starttls,
                });
                message.success("已保存");
                form.setFieldValue("password", "");
                await load();
              } catch (e) {
                message.error(String(e));
              } finally {
                setLoading(false);
              }
            }}
          >
            保存
          </Button>
          <Button
            style={{ marginLeft: 8 }}
            onClick={async () => {
              try {
                await apiPost("/admin/settings/email/test", {});
                message.success("测试邮件已发送");
              } catch (e) {
                message.error(String(e));
              }
            }}
          >
            发送测试邮件
          </Button>
        </Form>
      </Card>
    </div>
  );
}
