import { MailOutlined, SafetyOutlined, CloudUploadOutlined, RightOutlined } from "@ant-design/icons";
import { Card, Col, Row, Typography, Tag } from "antd";
import { useNavigate } from "react-router-dom";
import { getUser } from "../api/auth";

type HubItem = {
  key: string;
  title: string;
  desc: string;
  path: string;
  icon: React.ReactNode;
  adminOnly?: boolean;
};

const ITEMS: HubItem[] = [
  {
    key: "security",
    title: "平台安全",
    desc: "Bootstrap Token、Auth Secret、管理员密码。敏感项默认锁定，详情内解锁后配置。",
    path: "/settings/security",
    icon: <SafetyOutlined style={{ fontSize: 22 }} />,
    adminOnly: true,
  },
  {
    key: "email",
    title: "邮件告警",
    desc: "SMTP 与告警收件人。节点离线、服务异常等通知在详情页完整配置。",
    path: "/settings/email",
    icon: <MailOutlined style={{ fontSize: 22 }} />,
  },
  {
    key: "artifacts",
    title: "升级制品",
    desc: "上传 GFC 客户端 runtime 包（tar.gz），供设备详情页单设备下发 OTA。",
    path: "/settings/artifacts",
    icon: <CloudUploadOutlined style={{ fontSize: 22 }} />,
  },
];

export function SettingsPage() {
  const nav = useNavigate();
  const isAdmin = getUser()?.role === "admin";
  const visible = ITEMS.filter((i) => !i.adminOnly || isAdmin);

  return (
    <div>
      <Typography.Title level={4} style={{ marginBottom: 8 }}>
        系统设置
      </Typography.Title>
      <Typography.Paragraph type="secondary" style={{ marginBottom: 24 }}>
        汇总平台运维入口。点击卡片进入详情进行深度配置。
      </Typography.Paragraph>
      <Row gutter={[16, 16]}>
        {visible.map((item) => (
          <Col xs={24} md={12} lg={8} key={item.key}>
            <Card hoverable onClick={() => nav(item.path)} styles={{ body: { minHeight: 140 } }}>
              <div style={{ display: "flex", justifyContent: "space-between", gap: 12 }}>
                <div>
                  <div style={{ marginBottom: 8, color: "#1677ff" }}>{item.icon}</div>
                  <Typography.Title level={5} style={{ margin: 0 }}>
                    {item.title}
                  </Typography.Title>
                  <Typography.Paragraph type="secondary" style={{ marginTop: 8, marginBottom: 0 }}>
                    {item.desc}
                  </Typography.Paragraph>
                </div>
                <RightOutlined style={{ color: "#bfbfbf", alignSelf: "center" }} />
              </div>
              {item.adminOnly ? (
                <Tag color="gold" style={{ marginTop: 12 }}>
                  仅管理员
                </Tag>
              ) : null}
            </Card>
          </Col>
        ))}
      </Row>
    </div>
  );
}
