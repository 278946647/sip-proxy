import { Card, Col, Row, Statistic, Table, Tag, Typography } from "antd";
import { useEffect, useMemo, useState } from "react";
import dayjs from "dayjs";
import { apiGet } from "../api/client";
import { alertCategory, mapDashboard, mapSocks, type AlertEvent, type NodeRow, type SocksProfile } from "../types";

function alertTypeLabel(type: string): string {
  if (type.startsWith("socks_down_")) return "SOCKS 故障";
  if (type.startsWith("service_down_")) return `服务 ${type.replace("service_down_", "")}`;
  if (type === "node_offline") return "节点离线";
  if (type === "config_apply_failed") return "配置失败";
  return type;
}

function countSuffix(
  ok: number,
  bad: number,
  okLabel: string,
  badLabel: string
) {
  return (
    <span style={{ fontSize: 14, fontWeight: "normal" }}>
      / {okLabel} <span style={{ color: "#3f8600" }}>{ok}</span>
      {bad > 0 && (
        <>
          {" "}
          / {badLabel} <span style={{ color: "#cf1322" }}>{bad}</span>
        </>
      )}
    </span>
  );
}

export function DashboardPage() {
  const [stats, setStats] = useState({
    nodeTotal: 0,
    nodeOnline: 0,
    lineTotal: 0,
    lineActive: 0,
    socksTotal: 0,
    socksOnline: 0,
    socksOffline: 0,
    alertOpen: 0,
    socksAlertOpen: 0,
  });
  const [nodes, setNodes] = useState<NodeRow[]>([]);
  const [alerts, setAlerts] = useState<AlertEvent[]>([]);
  const [offlineSocks, setOfflineSocks] = useState<SocksProfile[]>([]);

  useEffect(() => {
    const load = async () => {
      const d = await apiGet<Record<string, unknown>>("/admin/dashboard");
      setStats(mapDashboard(d));
      setNodes(await apiGet<NodeRow[]>("/admin/nodes"));
      const socks = (await apiGet<Record<string, unknown>[]>("/admin/socks")).map(mapSocks);
      setOfflineSocks(socks.filter((s) => !s.isHealthy));
      const a = await apiGet<Record<string, unknown>[]>("/admin/alerts?limit=50&active_only=true");
      const mapped = a.map((x) => ({
        id: x.id as number,
        nodeId: x.node_id as number | null,
        lineId: x.line_id as number | null,
        level: x.level as string,
        type: x.type as string,
        message: x.message as string,
        createdAt: x.created_at as string,
      }));
      mapped.sort((x, y) => {
        const xs = alertCategory(x.type) === "socks" ? 0 : 1;
        const ys = alertCategory(y.type) === "socks" ? 0 : 1;
        if (xs !== ys) return xs - ys;
        return new Date(y.createdAt).getTime() - new Date(x.createdAt).getTime();
      });
      setAlerts(mapped.slice(0, 12));
    };
    void load();
    const t = setInterval(() => void load(), 5000);
    return () => clearInterval(t);
  }, []);

  const socksAlertCount = useMemo(
    () => alerts.filter((a) => alertCategory(a.type) === "socks").length,
    [alerts]
  );

  return (
    <div>
      <Typography.Title level={4} style={{ marginTop: 0 }}>
        仪表盘
      </Typography.Title>
      <Row gutter={16}>
        <Col span={5}>
          <Card className="gfc-stat-card">
            <Statistic
              title="转发节点"
              value={stats.nodeTotal}
              suffix={countSuffix(
                stats.nodeOnline,
                stats.nodeTotal - stats.nodeOnline,
                "在线",
                "离线"
              )}
            />
          </Card>
        </Col>
        <Col span={5}>
          <Card className="gfc-stat-card">
            <Statistic
              title="客户线路"
              value={stats.lineTotal}
              suffix={countSuffix(
                stats.lineActive,
                stats.lineTotal - stats.lineActive,
                "激活",
                "未激活"
              )}
            />
          </Card>
        </Col>
        <Col span={5}>
          <Card className="gfc-stat-card">
            <Statistic
              title="SOCKS 代理"
              value={stats.socksTotal}
              suffix={countSuffix(
                stats.socksOnline,
                stats.socksOffline,
                "在线",
                "离线"
              )}
            />
          </Card>
        </Col>
        <Col span={4}>
          <Card className="gfc-stat-card">
            <Statistic
              title="待处理告警"
              value={stats.alertOpen}
              suffix={
                stats.socksAlertOpen > 0 ? (
                  <span style={{ fontSize: 14 }}>含 SOCKS {stats.socksAlertOpen}</span>
                ) : undefined
              }
              valueStyle={{ color: stats.alertOpen ? "#cf1322" : undefined }}
            />
          </Card>
        </Col>
      </Row>

      {offlineSocks.length > 0 && (
        <Card title="离线 SOCKS 代理" size="small" style={{ marginTop: 16 }}>
          {offlineSocks.map((s) => (
            <Tag key={s.id} color="red" style={{ marginBottom: 4 }}>
              {s.name} ({s.addressDisplay || `${s.host}:${s.port}`})
            </Tag>
          ))}
        </Card>
      )}

      <Row gutter={16} style={{ marginTop: 16 }}>
        <Col span={14}>
          <Card title="转发节点状态">
            <Table
              size="small"
              rowKey="id"
              pagination={false}
              dataSource={nodes}
              columns={[
                { title: "名称", dataIndex: "name" },
                { title: "Region", dataIndex: "region" },
                {
                  title: "状态",
                  render: (_, r) =>
                    r.online ? <Tag color="green">在线</Tag> : <Tag color="default">离线</Tag>,
                },
                { title: "最近心跳", dataIndex: "lastSeenAt", ellipsis: true },
              ]}
            />
          </Card>
        </Col>
        <Col span={10}>
          <Card
            title="当前告警"
            extra={
              socksAlertCount > 0 ? (
                <Tag color="orange">SOCKS 相关 {socksAlertCount}</Tag>
              ) : null
            }
          >
            <Table
              size="small"
              rowKey="id"
              pagination={false}
              dataSource={alerts}
              columns={[
                {
                  title: "级别",
                  dataIndex: "level",
                  width: 72,
                  render: (v: string) => (
                    <Tag color={v === "critical" ? "red" : v === "warn" ? "orange" : "blue"}>{v}</Tag>
                  ),
                },
                {
                  title: "类型",
                  dataIndex: "type",
                  width: 100,
                  render: (t: string) => {
                    const cat = alertCategory(t);
                    return (
                      <Tag color={cat === "socks" ? "volcano" : cat === "node" ? "blue" : "default"}>
                        {alertTypeLabel(t)}
                      </Tag>
                    );
                  },
                },
                { title: "消息", dataIndex: "message", ellipsis: true },
                {
                  title: "时间",
                  dataIndex: "createdAt",
                  width: 96,
                  render: (v: string) => dayjs(v).format("MM-DD HH:mm"),
                },
              ]}
            />
          </Card>
        </Col>
      </Row>
    </div>
  );
}
