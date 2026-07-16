import {
  Button,
  Col,
  Descriptions,
  Form,
  Input,
  InputNumber,
  Row,
  Space,
  Switch,
  Tag,
  Typography,
  message,
} from "antd";
import { ArrowLeftOutlined } from "@ant-design/icons";
import { LineCodeField } from "../components/LineCodeField";
import { TrafficStatsPanel } from "../components/TrafficStatsPanel";
import { useEffect, useState } from "react";
import { Link, useNavigate, useParams } from "react-router-dom";
import { formatApiTime, nowDisplay } from "../utils/datetime";
import { apiDelete, apiGet, apiPatch } from "../api/client";
import { confirmLineEnableChange } from "../utils/lineEnableConfirm";
import { confirmDeleteLine } from "../utils/dangerousConfirm";
import { mapLineDetail, type FlowStat, type LineDetail } from "../types";
import { getUser } from "../api/auth";
import { permissionsFromUser } from "../utils/permissions";

function mapFlowRows(flow: Record<string, unknown>[]) {
  return flow.map((x) => ({
    id: x.id as number,
    nodeId: x.node_id as number,
    lineId: x.line_id as number | null,
    windowStart: x.window_start as string,
    windowSeconds: x.window_seconds as number,
    bytesIn: x.bytes_in as number,
    bytesOut: x.bytes_out as number,
    activeConns: x.active_conns as number,
  }));
}

export function LineDetailPage() {
  const { id } = useParams();
  const nav = useNavigate();
  const [line, setLine] = useState<LineDetail | null>(null);
  const [form] = Form.useForm();
  const [saving, setSaving] = useState(false);
  const [bandwidthDraft, setBandwidthDraft] = useState<number | null>(null);
  const [bandwidthSaving, setBandwidthSaving] = useState(false);
  const [enableSaving, setEnableSaving] = useState(false);
  const [flowStats, setFlowStats] = useState<FlowStat[]>([]);
  const [flowUpdatedAt, setFlowUpdatedAt] = useState(nowDisplay().format("YYYY-MM-DD HH:mm:ss"));
  const perms = permissionsFromUser(getUser());

  const load = async () => {
    const raw = await apiGet<Record<string, unknown>>(`/admin/lines/${id}`);
    const d = mapLineDetail(raw);
    setLine(d);
    setBandwidthDraft(d.bandwidthMbps);
    form.setFieldsValue({
      remark: d.remark,
      socksRemark: d.socksRemark,
    });
    if (d.lineType === "client") {
      try {
        const flow = await apiGet<Record<string, unknown>[]>(`/admin/lines/${id}/flow-stats?hours=24`);
        setFlowStats(mapFlowRows(flow));
        setFlowUpdatedAt(nowDisplay().format("YYYY-MM-DD HH:mm:ss"));
      } catch (e) {
        console.warn("flow-stats load failed", e);
        setFlowStats([]);
      }
    } else {
      setFlowStats([]);
    }
  };

  const refreshFlowStats = async () => {
    if (!id) return;
    const flow = await apiGet<Record<string, unknown>[]>(`/admin/lines/${id}/flow-stats?hours=24`);
    setFlowStats(mapFlowRows(flow));
    setFlowUpdatedAt(nowDisplay().format("YYYY-MM-DD HH:mm:ss"));
  };

  useEffect(() => {
    setLine(null);
    void load().catch((e) => message.error(String(e)));
    const timer = window.setInterval(() => {
      if (!id) return;
      void refreshFlowStats().catch(() => undefined);
    }, 15_000);
    return () => window.clearInterval(timer);
  }, [id]);

  const toggleEnabled = (checked: boolean) => {
    if (!id || !line) return;
    confirmLineEnableChange(checked, line.tid, async () => {
      setEnableSaving(true);
      try {
        await apiPatch(`/admin/lines/${id}?operator=${localStorage.getItem("gfc_user") || "admin"}`, {
          is_enabled: checked,
        });
        message.success(checked ? "线路已启用，客户端将在下次拉取配置后恢复代理" : "线路已禁用，客户端将切换为直连模式");
        await load();
      } catch (e) {
        message.error(String(e));
      } finally {
        setEnableSaving(false);
      }
    });
  };

  const saveBandwidth = async () => {
    if (!id || bandwidthDraft == null) return;
    const mbps = Math.floor(bandwidthDraft);
    if (!Number.isFinite(mbps) || mbps < 1) {
      message.error("带宽须为正整数 (Mbps)");
      return;
    }
    setBandwidthSaving(true);
    try {
      await apiPatch(`/admin/lines/${id}?operator=${localStorage.getItem("gfc_user") || "admin"}`, {
        bandwidth_mbps: mbps,
      });
      message.success("带宽已保存，客户端将在下次拉取配置后自动生效");
      await load();
    } catch (e) {
      message.error(String(e));
    } finally {
      setBandwidthSaving(false);
    }
  };

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
        {perms.canDeleteStructural && (
        <Button
          danger
          onClick={() =>
            confirmDeleteLine(
              line.tid,
              async () => {
                await apiDelete(`/admin/lines/${line.id}`);
                message.success("已删除");
                nav("/lines");
              },
              { boundDeviceName: line.clientDeviceName }
            )
          }
        >
          删除线路
        </Button>
        )}
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
            <Space>
              <Switch
                checked={line.isEnabled}
                loading={enableSaving}
                checkedChildren="启用"
                unCheckedChildren="禁用"
                onChange={(checked) => toggleEnabled(checked)}
              />
              <Tag color={line.isEnabled ? "green" : "default"}>{line.isEnabled ? "代理可用" : "已停用代理"}</Tag>
            </Space>
          </Descriptions.Item>
          <Descriptions.Item label="带宽">
            <Space>
              <InputNumber
                min={1}
                max={10000}
                precision={0}
                value={bandwidthDraft ?? line.bandwidthMbps}
                onChange={(v) => setBandwidthDraft(v == null ? null : Math.floor(v))}
                addonAfter="Mbps"
                style={{ width: 160 }}
              />
              <Button
                type="primary"
                size="small"
                loading={bandwidthSaving}
                disabled={
                  bandwidthDraft == null ||
                  !Number.isFinite(bandwidthDraft) ||
                  Math.floor(bandwidthDraft) === line.bandwidthMbps
                }
                onClick={() => void saveBandwidth()}
              >
                保存
              </Button>
            </Space>
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
            {formatApiTime(line.createdAt)}
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
        </Descriptions>
      </div>

      {line.lineType === "client" && (
        <div className="line-detail-section">
          <Typography.Title level={5}>线路码</Typography.Title>
          <LineCodeField value={line.lineCodeB32 || ""} />
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
        <div className="line-detail-label">SOCKS / 出局方式</div>
        <div className="line-detail-value" style={{ wordBreak: "break-all" }}>
          {socksUri}
        </div>
        <div style={{ marginTop: 12 }}>
          <Link to="/proxies">在代理配置中编辑 SOCKS →</Link>
        </div>
      </div>

      {line.lineType === "client" && (
        <div className="line-detail-section">
          <TrafficStatsPanel stats={flowStats} updatedAt={flowUpdatedAt} />
        </div>
      )}
    </div>
  );
}
