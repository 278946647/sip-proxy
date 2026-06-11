import { LockOutlined, UnlockOutlined } from "@ant-design/icons";
import {
  Alert,
  Button,
  Card,
  Form,
  Input,
  InputNumber,
  Modal,
  Switch,
  Tag,
  Typography,
  message,
} from "antd";
import { useEffect, useState } from "react";
import { apiGet, apiPost, apiPut } from "../api/client";
import { getUser } from "../api/auth";

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

type SecuritySettings = {
  bootstrap_tokens: string;
  auth_secret_configured: boolean;
  generated_admin_password?: string | null;
  source: string;
  syncs_to_nodes: string[];
  updated_at?: string;
};

export function SettingsPage() {
  const [form] = Form.useForm();
  const [secForm] = Form.useForm();
  const [loading, setLoading] = useState(false);
  const [secLoading, setSecLoading] = useState(false);
  const [meta, setMeta] = useState<EmailSettings | null>(null);
  const [security, setSecurity] = useState<SecuritySettings | null>(null);
  const [secEditable, setSecEditable] = useState(false);
  const isAdmin = getUser()?.role === "admin";

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

  const loadSecurity = async () => {
    if (!isAdmin) return;
    const s = await apiGet<SecuritySettings>("/admin/settings/security");
    setSecurity(s);
    secForm.setFieldsValue({
      bootstrap_tokens: s.bootstrap_tokens,
    });
  };

  useEffect(() => {
    void load().catch((e) => message.error(String(e)));
    void loadSecurity().catch((e) => message.error(String(e)));
  }, [form, secForm, isAdmin]);

  const doSaveSecurity = async () => {
    const v = await secForm.validateFields();
    const hasChange = v.bootstrap_tokens || v.auth_secret || v.admin_password;
    if (!hasChange) {
      message.warning("请填写要修改的项");
      return;
    }
    setSecLoading(true);
    try {
      await apiPut("/admin/settings/security", {
        confirm: true,
        bootstrap_tokens: v.bootstrap_tokens || null,
        auth_secret: v.auth_secret || null,
        admin_password: v.admin_password || null,
      });
      message.success("安全设置已保存");
      secForm.setFieldsValue({ auth_secret: "", admin_password: "" });
      await loadSecurity();
      lockSecurityForm();
    } catch (e) {
      message.error(String(e));
    } finally {
      setSecLoading(false);
    }
  };

  const lockSecurityForm = () => {
    setSecEditable(false);
    secForm.setFieldsValue({
      bootstrap_tokens: security?.bootstrap_tokens ?? "",
      auth_secret: "",
      admin_password: "",
    });
  };

  const saveSecurity = () => {
    if (!secEditable) {
      message.warning("请先点击「解锁编辑」");
      return;
    }
    Modal.confirm({
      title: "确认修改平台安全设置？",
      content: (
        <div>
          <p>修改 Bootstrap Token 将在约 10 秒内同步到所有转发节点的 /etc/gfc-node/gfc.env。</p>
          <p>修改 Auth Secret 将使所有已登录 Web 会话失效，需重新登录。</p>
          <p>修改管理员密码后请使用新密码登录。</p>
        </div>
      ),
      okText: "继续",
      cancelText: "取消",
      onOk: () => {
        Modal.confirm({
          title: "再次确认保存",
          content: "此操作影响平台安全与转发节点激活，确定要保存吗？",
          okText: "确定保存",
          okType: "danger",
          cancelText: "取消",
          onOk: () => void doSaveSecurity(),
        });
      },
    });
  };

  return (
    <div>
      <Typography.Title level={4}>系统设置</Typography.Title>

      {isAdmin && (
        <Card title="平台安全" style={{ marginBottom: 16 }}>
          <Typography.Paragraph type="secondary">
            首次安装时系统会自动生成 Bootstrap Token、Auth Secret 与管理员密码（写入数据库）。
            修改 Bootstrap Token 会主动同步到转发节点；仅管理员可修改，保存前需确认。
          </Typography.Paragraph>
          {security?.generated_admin_password && (
            <Alert
              type="warning"
              showIcon
              style={{ marginBottom: 16 }}
              message="首次安装自动生成的管理员密码"
              description={
                <Typography.Text copyable code>
                  {security.generated_admin_password}
                </Typography.Text>
              }
            />
          )}
          {!secEditable && (
            <Alert
              type="info"
              showIcon
              icon={<LockOutlined />}
              style={{ marginBottom: 12 }}
              message="敏感项已锁定"
              description="Bootstrap Token 当前为只读展示，不可编辑。点击「解锁编辑」并确认后，方可修改各项安全设置。"
            />
          )}
          <div style={{ marginBottom: 12 }}>
            {!secEditable ? (
              <Button
                type="primary"
                ghost
                icon={<UnlockOutlined />}
                onClick={() => {
                  Modal.confirm({
                    title: "解锁平台安全设置？",
                    content: "解锁后可编辑 Bootstrap Token 等敏感项。请勿在误触情况下保存。",
                    okText: "解锁编辑",
                    onOk: () => {
                      setSecEditable(true);
                      secForm.setFieldsValue({
                        bootstrap_tokens: security?.bootstrap_tokens ?? "",
                        auth_secret: "",
                        admin_password: "",
                      });
                    },
                  });
                }}
              >
                解锁编辑
              </Button>
            ) : (
              <Button danger icon={<LockOutlined />} onClick={() => lockSecurityForm()}>
                锁定
              </Button>
            )}
          </div>
          {!secEditable ? (
            <div style={{ maxWidth: 560 }}>
              <div style={{ marginBottom: 20 }}>
                <Typography.Text strong>Bootstrap Token（转发节点激活）</Typography.Text>
                <div style={{ color: "#8c8c8c", fontSize: 12, marginBottom: 8 }}>
                  已锁定 — 仅可复制，不可编辑
                </div>
                <div
                  style={{
                    display: "flex",
                    alignItems: "center",
                    gap: 12,
                    padding: "10px 14px",
                    background: "#f5f5f5",
                    border: "1px dashed #bfbfbf",
                    borderRadius: 8,
                  }}
                >
                  <Typography.Text copyable code style={{ margin: 0, flex: 1, wordBreak: "break-all" }}>
                    {security?.bootstrap_tokens || "—"}
                  </Typography.Text>
                  <Tag icon={<LockOutlined />} color="processing">
                    已锁定
                  </Tag>
                </div>
              </div>
              <div style={{ marginBottom: 20 }}>
                <Typography.Text strong>Auth Secret（Web 会话签名）</Typography.Text>
                <div
                  style={{
                    marginTop: 8,
                    padding: "10px 14px",
                    background: "#f5f5f5",
                    border: "1px dashed #bfbfbf",
                    borderRadius: 8,
                    color: "#8c8c8c",
                  }}
                >
                  {security?.auth_secret_configured ? "已配置（解锁后可修改）" : "未单独配置"}
                  <Tag icon={<LockOutlined />} color="processing" style={{ marginLeft: 8 }}>
                    已锁定
                  </Tag>
                </div>
              </div>
              <div style={{ marginBottom: 20 }}>
                <Typography.Text strong>管理员新密码</Typography.Text>
                <div
                  style={{
                    marginTop: 8,
                    padding: "10px 14px",
                    background: "#f5f5f5",
                    border: "1px dashed #bfbfbf",
                    borderRadius: 8,
                    color: "#8c8c8c",
                  }}
                >
                  解锁后可设置新密码
                  <Tag icon={<LockOutlined />} color="processing" style={{ marginLeft: 8 }}>
                    已锁定
                  </Tag>
                </div>
              </div>
              <Button type="primary" disabled>
                保存安全设置（请先解锁）
              </Button>
            </div>
          ) : (
            <Form form={secForm} layout="vertical" style={{ maxWidth: 560 }} key="security-edit-form">
              <Form.Item
                name="bootstrap_tokens"
                label="Bootstrap Token（转发节点激活）"
                extra="与 install.env 中 BOOTSTRAP_TOKEN 一致；保存后自动同步到在线节点"
                rules={[{ required: true, message: "请输入 Bootstrap Token" }]}
              >
                <Input autoComplete="off" placeholder="输入新的 Bootstrap Token" />
              </Form.Item>
              <Form.Item
                name="auth_secret"
                label="Auth Secret（Web 会话签名）"
                extra={security?.auth_secret_configured ? "已配置；留空表示不修改" : "留空表示不修改"}
              >
                <Input.Password autoComplete="new-password" placeholder="留空不修改" />
              </Form.Item>
              <Form.Item
                name="admin_password"
                label="管理员新密码"
                extra="至少 8 位；留空表示不修改"
              >
                <Input.Password autoComplete="new-password" placeholder="留空不修改" />
              </Form.Item>
              <Button type="primary" loading={secLoading} onClick={() => saveSecurity()}>
                保存安全设置
              </Button>
            </Form>
          )}
          <Typography.Text type="secondary" style={{ fontSize: 11, display: "block", marginTop: 16 }}>
            安全设置界面 v2 — 锁定态为灰色虚线只读框（非输入框）
          </Typography.Text>
        </Card>
      )}

      <Card title="邮件告警 (SMTP)">
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
