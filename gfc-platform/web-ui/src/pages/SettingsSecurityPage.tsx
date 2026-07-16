import { ArrowLeftOutlined, LockOutlined, UnlockOutlined } from "@ant-design/icons";
import {
  Alert,
  Button,
  Card,
  Form,
  Input,
  Modal,
  Space,
  Tag,
  Typography,
  message,
} from "antd";
import { useEffect, useState } from "react";
import { useNavigate } from "react-router-dom";
import { apiGet, apiPut } from "../api/client";
import { getUser } from "../api/auth";

type SecuritySettings = {
  bootstrap_tokens: string;
  auth_secret_configured: boolean;
  generated_admin_password?: string | null;
  source: string;
  syncs_to_nodes: string[];
  updated_at?: string;
};

export function SettingsSecurityPage() {
  const nav = useNavigate();
  const [secForm] = Form.useForm();
  const [secLoading, setSecLoading] = useState(false);
  const [security, setSecurity] = useState<SecuritySettings | null>(null);
  const [secEditable, setSecEditable] = useState(false);
  const isAdmin = getUser()?.role === "admin";

  const loadSecurity = async () => {
    if (!isAdmin) return;
    const s = await apiGet<SecuritySettings>("/admin/settings/security");
    setSecurity(s);
    secForm.setFieldsValue({ bootstrap_tokens: s.bootstrap_tokens });
  };

  useEffect(() => {
    void loadSecurity().catch((e) => message.error(String(e)));
  }, [secForm, isAdmin]);

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
      setSecEditable(false);
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

  if (!isAdmin) {
    return (
      <div>
        <Button icon={<ArrowLeftOutlined />} onClick={() => nav("/settings")} style={{ marginBottom: 16 }}>
          返回系统设置
        </Button>
        <Alert type="error" message="仅管理员可查看平台安全设置" />
      </div>
    );
  }

  return (
    <div>
      <Space style={{ marginBottom: 16 }}>
        <Button icon={<ArrowLeftOutlined />} onClick={() => nav("/settings")}>
          返回系统设置
        </Button>
      </Space>
      <Typography.Title level={4}>平台安全</Typography.Title>
      <Card>
        <Typography.Paragraph type="secondary">
          首次安装时系统会自动生成 Bootstrap Token、Auth Secret 与管理员密码（写入数据库）。
          修改 Bootstrap Token 会主动同步到转发节点；仅管理员可修改，保存前需确认。
        </Typography.Paragraph>
        {security?.generated_admin_password ? (
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
        ) : null}
        {!secEditable ? (
          <Alert
            type="info"
            showIcon
            icon={<LockOutlined />}
            style={{ marginBottom: 12 }}
            message="敏感项已锁定"
            description="Bootstrap Token 当前为只读展示。点击「解锁编辑」后方可修改。"
          />
        ) : null}
        <div style={{ marginBottom: 12 }}>
          {!secEditable ? (
            <Button
              type="primary"
              ghost
              icon={<UnlockOutlined />}
              onClick={() => {
                Modal.confirm({
                  title: "解锁平台安全设置？",
                  content: "解锁后可编辑 Bootstrap Token 等敏感项。",
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
            <Typography.Text strong>Bootstrap Token</Typography.Text>
            <div
              style={{
                marginTop: 8,
                marginBottom: 16,
                padding: "10px 14px",
                background: "#f5f5f5",
                borderRadius: 8,
              }}
            >
              <Typography.Text copyable code>
                {security?.bootstrap_tokens || "—"}
              </Typography.Text>
              <Tag icon={<LockOutlined />} color="processing" style={{ marginLeft: 8 }}>
                已锁定
              </Tag>
            </div>
            <Button type="primary" disabled>
              保存安全设置（请先解锁）
            </Button>
          </div>
        ) : (
          <Form form={secForm} layout="vertical" style={{ maxWidth: 560 }}>
            <Form.Item
              name="bootstrap_tokens"
              label="Bootstrap Token（转发节点激活）"
              rules={[{ required: true, message: "请输入 Bootstrap Token" }]}
            >
              <Input autoComplete="off" />
            </Form.Item>
            <Form.Item name="auth_secret" label="Auth Secret" extra="留空表示不修改">
              <Input.Password autoComplete="new-password" placeholder="留空不修改" />
            </Form.Item>
            <Form.Item name="admin_password" label="管理员新密码" extra="至少 8 位；留空不修改">
              <Input.Password autoComplete="new-password" placeholder="留空不修改" />
            </Form.Item>
            <Button type="primary" loading={secLoading} onClick={() => saveSecurity()}>
              保存安全设置
            </Button>
          </Form>
        )}
      </Card>
    </div>
  );
}
