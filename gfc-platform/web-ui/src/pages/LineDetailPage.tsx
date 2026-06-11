import {
  Button,
  Col,
  Descriptions,
  Form,
  Input,
  Popconfirm,
  Row,
  Space,
  Tag,
  Typography,
  message,
} from "antd";
import { ArrowLeftOutlined, CopyOutlined } from "@ant-design/icons";
import { useEffect, useState } from "react";
import { Link, useNavigate, useParams } from "react-router-dom";
import dayjs from "dayjs";
import { apiDelete, apiGet, apiPatch } from "../api/client";
import { mapLineDetail, type LineDetail } from "../types";

export function LineDetailPage() {
  const { id } = useParams();
  const nav = useNavigate();
  const [line, setLine] = useState<LineDetail | null>(null);
  const [form] = Form.useForm();
  const [saving, setSaving] = useState(false);

  const load = async () => {
    const raw = await apiGet<Record<string, unknown>>(`/admin/lines/${id}`);
    const d = mapLineDetail(raw);
    setLine(d);
    form.setFieldsValue({
      remark: d.remark,
      socksRemark: d.socksRemark,
    });
  };

  useEffect(() => {
    void load().catch((e) => message.error(String(e)));
  }, [id]);

  const saveRemarks = async () => {
    const v = await form.validateFields();
    setSaving(true);
    try {
      await apiPatch(`/admin/lines/${id}?operator=${localStorage.getItem("gfc_user") || "admin"}`, {
        remark: v.remark,
        socks_remark: v.socksRemark,
      });
      message.success("备注已保存");
      await load();
    } catch (e) {
      message.error(String(e));
    } finally {
      setSaving(false);
    }
  };

  const copyLineCode = async () => {
    try {
      const res = await apiGet<{ line_code_b32: string }>(`/admin/lines/${id}/line-code`);
      await navigator.clipboard.writeText(res.line_code_b32);
      message.success("线路码已复制");
      await load();
    } catch (e) {
      message.error(String(e));
    }
  };

  if (!line) return null;

  const socksUri =
    line.socksHost && line.socksPort
      ? line.socksUsername && line.socksPassword
        ? `${line.socksUsername}:${line.socksPassword}@${line.socksHost}:${line.socksPort}`
        : `${line.socksHost}:${line.socksPort}`
      : "节点本地网络出局（未绑定 SOCKS）";

  return (
    <div>
      <Space style={{ marginBottom: 16 }}>
        <Button icon={<ArrowLeftOutlined />} onClick={() => nav("/lines")}>
          返回列表
        </Button>
        <Popconfirm
          title={`删除线路 ${line.tid}？`}
          onConfirm={async () => {
            await apiDelete(`/admin/lines/${line.id}`);
            message.success("已删除");
            nav("/lines");
          }}
        >
          <Button danger>删除线路</Button>
        </Popconfirm>
      </Space>

      <Typography.Title level={4}>线路详情 - {line.tid}</Typography.Title>

      <div className="line-detail-section">
        <Typography.Title level={5}>基本信息</Typography.Title>
        <Descriptions column={3} bordered size="small">
          <Descriptions.Item label="TID">{line.tid}</Descriptions.Item>
          <Descriptions.Item label="类型">
            <Tag>{line.lineType === "forward" ? "转发线路" : "客户端线路"}</Tag>
          </Descriptions.Item>
          <Descriptions.Item label="状态">
            <Tag color={line.status === "active" ? "green" : "default"}>
              {line.status === "active" ? "激活" : "停用"}
            </Tag>
          </Descriptions.Item>
          <Descriptions.Item label="带宽">
            <Tag color="blue">{line.bandwidthMbps}Mbps</Tag>
          </Descriptions.Item>
          <Descriptions.Item label="节点">{line.nodeName}</Descriptions.Item>
          <Descriptions.Item label="国家/地区">{line.country || "-"}</Descriptions.Item>
          <Descriptions.Item label="客户端">
            {line.clientDeviceId ? (
              <Link to={`/client-devices/${line.clientDeviceId}`}>
                {line.clientDeviceName || `#${line.clientDeviceId}`}
              </Link>
            ) : (
              "未绑定"
            )}
          </Descriptions.Item>
          <Descriptions.Item label="创建者">{line.createdBy}</Descriptions.Item>
          <Descriptions.Item label="创建时间">
            {dayjs(line.createdAt).format("YYYY-MM-DD HH:mm:ss")}
          </Descriptions.Item>
          <Descriptions.Item label="VLESS UUID">{line.clientUuid || "-"}</Descriptions.Item>
          <Descriptions.Item label="当前配置版本" span={2}>
            {line.currentConfigVersion || "-"}
          </Descriptions.Item>
          {line.lineType === "forward" && (
            <Descriptions.Item label="源 IP 段" span={3}>
              {line.sourceCidrs.join(", ")}
            </Descriptions.Item>
          )}
          <Descriptions.Item label="备注" span={3}>
            {line.remark || "-"}
          </Descriptions.Item>
        </Descriptions>
      </div>

      {line.lineType === "client" && (
        <div className="line-detail-section">
          <Typography.Title level={5}>线路码（Base32）</Typography.Title>
          <Typography.Paragraph type="secondary">
            创建线路时自动生成。将下方编码写入客户端盒子，盒子解码后激活并拉取配置。
          </Typography.Paragraph>
          <Input.TextArea
            rows={4}
            readOnly
            value={line.lineCodeB32 || "（点击刷新获取）"}
            style={{ fontFamily: "monospace", marginBottom: 8 }}
          />
          <Button type="primary" icon={<CopyOutlined />} onClick={() => void copyLineCode()}>
            复制线路码
          </Button>
        </div>
      )}

      <div className="line-detail-section">
        <Typography.Title level={5}>编辑备注</Typography.Title>
        <Form form={form} layout="vertical">
          <Row gutter={16}>
            <Col span={12}>
              <Form.Item name="remark" label="备注">
                <Input.TextArea rows={3} />
              </Form.Item>
            </Col>
            <Col span={12}>
              <Form.Item name="socksRemark" label="Socks5 配置备注">
                <Input.TextArea rows={3} />
              </Form.Item>
            </Col>
          </Row>
          <Button type="primary" loading={saving} onClick={() => void saveRemarks()}>
            保存备注
          </Button>
        </Form>
      </div>

      <div className="line-detail-section">
        <Typography.Title level={5}>出站配置</Typography.Title>
        <Row gutter={24}>
          <Col span={12}>
            <div className="line-detail-label">SOCKS / 出局方式</div>
            <div className="line-detail-value" style={{ wordBreak: "break-all" }}>
              {socksUri}
            </div>
          </Col>
          <Col span={12}>
            <div className="line-detail-label">Socks5 配置备注</div>
            <div className="line-detail-value">{line.socksRemark || "-"}</div>
          </Col>
        </Row>
        <div style={{ marginTop: 12 }}>
          <Link to="/proxies">在代理配置中编辑 SOCKS →</Link>
        </div>
      </div>
    </div>
  );
}
