import {
  Button,
  Card,
  Checkbox,
  Form,
  Input,
  InputNumber,
  Modal,
  Popconfirm,
  Select,
  Space,
  Table,
  Tag,
  Tooltip,
  Typography,
  message,
} from "antd";
import { MinusCircleOutlined, PlusOutlined as PlusIcon } from "@ant-design/icons";
import { useEffect, useMemo, useState } from "react";
import { apiDelete, apiGet, apiPatch, apiPost, apiPut } from "../api/client";
import type { StaticRoute } from "../types";

type VpnSummary = {
  enabled: boolean;
  remote: string | null;
  port: number;
  proto: string;
  dev: string;
  remoteNetworks: string[];
  tunnelNetwork: string | null;
  autoStaticRoutes: boolean;
  authMode: string;
  hasCerts: boolean;
  hasStaticKey: boolean;
};

type NodeRow = {
  id: number;
  nodeKey: string;
  name: string;
  region: string;
  publicIp: string | null;
  online: boolean;
  connectMode: string;
  vpnSummary: VpnSummary | null;
  agentVersion: string | null;
  currentConfigVersion: string | null;
  lastSeenAt: string | null;
  createdAt: string | null;
  staticRoutes: StaticRoute[];
  lastMetrics: { services?: Record<string, { active: boolean; status: string }> } | null;
};

type VpnConfig = {
  enabled?: boolean;
  auth_mode?: string;
  remote?: string;
  port?: number;
  proto?: string;
  dev?: string;
  ca?: string;
  cert?: string;
  key?: string;
  static_key?: string;
  tls_auth?: string | null;
  extra_config?: string | null;
  remote_networks?: string[];
  tunnel_network?: string | null;
  auto_static_routes?: boolean;
};

export function NodesPage() {
  const [nodes, setNodes] = useState<NodeRow[]>([]);
  const [editOpen, setEditOpen] = useState(false);
  const [vpnOpen, setVpnOpen] = useState(false);
  const [vyosOpen, setVyosOpen] = useState(false);
  const [vyosText, setVyosText] = useState("");
  const [routesOpen, setRoutesOpen] = useState(false);
  const [current, setCurrent] = useState<NodeRow | null>(null);
  const [pkiLoading, setPkiLoading] = useState(false);
  const [staticKeyLoading, setStaticKeyLoading] = useState(false);
  const [form] = Form.useForm();
  const [vpnForm] = Form.useForm();
  const [routesForm] = Form.useForm();

  const load = async () => {
    const rows = await apiGet<Record<string, unknown>[]>("/admin/nodes");
    setNodes(
      rows.map((r) => ({
        id: r.id as number,
        nodeKey: (r.nodeKey as string) || "",
        name: r.name as string,
        region: r.region as string,
        publicIp: (r.publicIp as string) || null,
        online: r.online as boolean,
        createdAt: (r.createdAt as string) || null,
        connectMode: (r.connectMode as string) || "ethernet",
        vpnSummary: (r.vpnSummary as VpnSummary) || null,
        agentVersion: r.agentVersion as string | null,
        currentConfigVersion: r.currentConfigVersion as string | null,
        lastSeenAt: r.lastSeenAt as string | null,
        staticRoutes: (r.staticRoutes as StaticRoute[]) || [],
        lastMetrics: r.lastMetrics as NodeRow["lastMetrics"],
      }))
    );
  };

  const suggestTunnelNetwork = async (nodeId: number) => {
    const res = await apiGet<{
      tunnelNetwork: string;
      vyosTunnelIp: string;
      nodeTunnelIp: string;
      pool: string;
    }>(`/admin/nodes/${nodeId}/vpn/tunnel-suggest`);
    vpnForm.setFieldValue("tunnelNetwork", res.tunnelNetwork);
    message.info(`建议网段 ${res.tunnelNetwork}（VyOS ${res.vyosTunnelIp} ↔ 节点 ${res.nodeTunnelIp}）`);
    return res.tunnelNetwork;
  };

  const openVpnModal = async (r: NodeRow) => {
    setCurrent(r);
    try {
      const detail = await apiGet<Record<string, unknown>>(`/admin/nodes/${r.id}`);
      const vpn = detail.vpnConfig as VpnConfig | null;
      const suggested = vpn?.tunnel_network
        ? null
        : await apiGet<{ tunnelNetwork: string }>(`/admin/nodes/${r.id}/vpn/tunnel-suggest`);
      if (vpn) {
        vpnForm.setFieldsValue({
          authMode: vpn.auth_mode ?? "pki",
          remote: vpn.remote,
          port: vpn.port ?? 1194,
          proto: vpn.proto ?? "udp",
          dev: vpn.dev ?? "tun0",
          ca: vpn.ca,
          cert: vpn.cert,
          key: vpn.key,
          staticKey: vpn.static_key,
          tlsAuth: vpn.tls_auth,
          extraConfig: vpn.extra_config,
          tunnelNetwork: vpn.tunnel_network ?? suggested?.tunnelNetwork ?? "",
          autoStaticRoutes: vpn.auto_static_routes !== false,
          remoteNetworks:
            vpn.remote_networks && vpn.remote_networks.length > 0
              ? vpn.remote_networks
              : [""],
        });
      } else {
        vpnForm.resetFields();
        vpnForm.setFieldsValue({
          authMode: "pki",
          port: 1194,
          proto: "udp",
          dev: "tun0",
          tunnelNetwork: suggested?.tunnelNetwork ?? "",
          autoStaticRoutes: true,
          remoteNetworks: [""],
        });
      }
      setVpnOpen(true);
    } catch (e) {
      message.error(String(e));
    }
  };

  const dupNames = useMemo(() => {
    const c = new Map<string, number>();
    nodes.forEach((n) => c.set(n.name, (c.get(n.name) || 0) + 1));
    return new Set([...c.entries()].filter(([, n]) => n > 1).map(([k]) => k));
  }, [nodes]);

  useEffect(() => {
    void load().catch((e) => message.error(String(e)));
    const t = setInterval(() => void load(), 5000);
    return () => clearInterval(t);
  }, []);

  return (
    <div>
      <Typography.Title level={4}>转发节点管理</Typography.Title>
      <Typography.Paragraph type="secondary">
        以 <strong>ID</strong>、<strong>节点指纹 nodeKey</strong>、<strong>公网 IP</strong> 区分同名节点。
        OpenVPN 模式下控制台下发客户端配置，Agent 自动写入 <code>/etc/openvpn/gfc-backbone/</code> 并重启服务；
        TPROXY 入口网卡随隧道 <code>dev</code> 下发（无需再手工设 <code>GFC_TPROXY_IFACE=tun0</code>）。
      </Typography.Paragraph>
      <Card>
        <Table
          rowKey="id"
          dataSource={nodes}
          columns={[
            { title: "ID", dataIndex: "id", width: 56 },
            {
              title: "名称",
              render: (_, r) => (
                <Space>
                  {r.name}
                  {dupNames.has(r.name) && (
                    <Tooltip title="存在同名节点，请用 ID / nodeKey / 公网 IP 区分">
                      <Tag color="orange">重名</Tag>
                    </Tooltip>
                  )}
                </Space>
              ),
            },
            {
              title: "指纹",
              dataIndex: "nodeKey",
              ellipsis: true,
              render: (k: string) => (
                <Typography.Text copyable code style={{ fontSize: 11 }}>
                  {k ? k.slice(0, 12) : "-"}
                </Typography.Text>
              ),
            },
            { title: "公网 IP", dataIndex: "publicIp", render: (v) => v || "-" },
            { title: "Region", dataIndex: "region" },
            {
              title: "连通",
              render: (_, r) =>
                r.online ? <Tag color="green">在线</Tag> : <Tag color="red">离线</Tag>,
            },
            {
              title: "接入方式",
              render: (_, r) =>
                r.connectMode === "openvpn" ? (
                  <Tooltip
                    title={
                      r.vpnSummary?.remote
                        ? `→ ${r.vpnSummary.remote}:${r.vpnSummary.port} (${r.vpnSummary.dev})`
                        : "已选 OpenVPN，待完善配置"
                    }
                  >
                    <Tag color="blue">OpenVPN</Tag>
                  </Tooltip>
                ) : (
                  <Tag>以太网直通</Tag>
                ),
            },
            {
              title: "服务状态",
              render: (_, r) => {
                const svc = r.lastMetrics?.services;
                if (!svc) return "-";
                return (
                  <Space size={4} wrap>
                    {Object.entries(svc).map(([k, v]) => (
                      <Tag key={k} color={v.active ? "green" : "red"}>
                        {k}
                      </Tag>
                    ))}
                  </Space>
                );
              },
            },
            { title: "Agent", dataIndex: "agentVersion", render: (v) => v || "-" },
            {
              title: "配置版本",
              dataIndex: "currentConfigVersion",
              ellipsis: true,
              render: (v) => v || "-",
            },
            {
              title: "操作",
              render: (_, r) => (
                <Space wrap>
                  <Button
                    type="link"
                    onClick={() => {
                      setCurrent(r);
                      form.setFieldsValue({
                        name: r.name,
                        region: r.region,
                        connectMode: r.connectMode,
                      });
                      setEditOpen(true);
                    }}
                  >
                    改名/模式
                  </Button>
                  <Button
                    type="link"
                    onClick={() => {
                      setCurrent(r);
                      routesForm.setFieldsValue({
                        routes: r.staticRoutes.length
                          ? r.staticRoutes
                          : [{ prefix: "", next_hop: "", device: "", comment: "" }],
                      });
                      setRoutesOpen(true);
                    }}
                  >
                    回程路由
                  </Button>
                  <Button type="link" onClick={() => void openVpnModal(r)}>
                    OpenVPN
                  </Button>
                  {!r.online && (
                    <Popconfirm
                      title={`删除节点 #${r.id}？`}
                      description="仅可删除无线路绑定的离线节点"
                      onConfirm={async () => {
                        try {
                          await apiDelete(`/admin/nodes/${r.id}`);
                          message.success("已删除");
                          await load();
                        } catch (e) {
                          message.error(String(e));
                        }
                      }}
                    >
                      <Button type="link" danger>
                        删除
                      </Button>
                    </Popconfirm>
                  )}
                </Space>
              ),
            },
          ]}
        />
      </Card>

      <Modal
        title="修改节点"
        open={editOpen}
        onOk={async () => {
          const v = await form.validateFields();
          await apiPatch(`/admin/nodes/${current!.id}`, {
            name: v.name,
            region: v.region,
            connect_mode: v.connectMode,
          });
          message.success("已保存，节点下次心跳同步名称");
          setEditOpen(false);
          await load();
        }}
        onCancel={() => setEditOpen(false)}
      >
        <Form form={form} layout="vertical">
          <Form.Item name="name" label="节点名称" rules={[{ required: true }]}>
            <Input />
          </Form.Item>
          <Form.Item name="region" label="Region">
            <Input />
          </Form.Item>
          <Form.Item name="connectMode" label="骨干接入">
            <Select
              options={[
                { label: "以太网直通", value: "ethernet" },
                { label: "OpenVPN Site-to-Site", value: "openvpn" },
              ]}
            />
          </Form.Item>
        </Form>
      </Modal>

      <Modal
        title={`回程静态路由 — ${current?.name} (#${current?.id})`}
        open={routesOpen}
        width={720}
        onOk={async () => {
          const v = await routesForm.validateFields();
          const routes = (v.routes as StaticRoute[]).filter((r) => r.prefix?.trim());
          await apiPut(`/admin/nodes/${current!.id}/routes`, routes);
          message.success("回程路由已下发，节点下次拉取配置时生效");
          setRoutesOpen(false);
          await load();
        }}
        onCancel={() => setRoutesOpen(false)}
      >
        <Typography.Paragraph type="secondary">
          将<strong>客户源网段</strong>的回复流量从转发节点送回 VyOS/骨干。OpenVPN 模式下可勾选「自动生成回程路由」，
          由平台根据线路 source_cidrs 与 remote_networks 合并下发（device=tun0）。
        </Typography.Paragraph>
        <Form form={routesForm} layout="vertical">
          <Form.List name="routes">
            {(fields, { add, remove }) => (
              <>
                {fields.map(({ key, name, ...rest }) => (
                  <Space key={key} align="baseline" style={{ display: "flex", marginBottom: 8 }}>
                    <Form.Item
                      {...rest}
                      name={[name, "prefix"]}
                      rules={[{ required: true, message: "CIDR" }]}
                    >
                      <Input placeholder="10.0.0.0/24" style={{ width: 150 }} />
                    </Form.Item>
                    <Form.Item {...rest} name={[name, "next_hop"]}>
                      <Input placeholder="VyOS 网关" style={{ width: 130 }} />
                    </Form.Item>
                    <Form.Item {...rest} name={[name, "device"]}>
                      <Input placeholder="eth1 / tun0" style={{ width: 90 }} />
                    </Form.Item>
                    <Form.Item {...rest} name={[name, "comment"]}>
                      <Input placeholder="备注" style={{ width: 100 }} />
                    </Form.Item>
                    <MinusCircleOutlined onClick={() => remove(name)} />
                  </Space>
                ))}
                <Button type="dashed" onClick={() => add()} block icon={<PlusIcon />}>
                  添加路由
                </Button>
              </>
            )}
          </Form.List>
        </Form>
      </Modal>

      <Modal
        title={`OpenVPN — ${current?.name} (#${current?.id})`}
        open={vpnOpen}
        width={760}
        onOk={async () => {
          const v = await vpnForm.validateFields();
          const remoteNetworks = ((v.remoteNetworks as string[]) || [])
            .map((s) => s.trim())
            .filter(Boolean);
          const authMode = (v.authMode as string) || "pki";
          await apiPut(`/admin/nodes/${current!.id}/vpn`, {
            enabled: true,
            auth_mode: authMode,
            remote: v.remote,
            port: v.port,
            proto: v.proto,
            dev: v.dev || "tun0",
            ca: authMode === "pki" ? v.ca : null,
            cert: authMode === "pki" ? v.cert : null,
            key: authMode === "pki" ? v.key : null,
            static_key: authMode === "static_key" ? v.staticKey : null,
            tls_auth: authMode === "pki" ? v.tlsAuth || null : null,
            extra_config: v.extraConfig || null,
            remote_networks: remoteNetworks,
            tunnel_network: (v.tunnelNetwork as string)?.trim() || null,
            auto_static_routes: v.autoStaticRoutes !== false,
          });
          message.success("OpenVPN 已下发，节点约 10 秒内拉取并应用");
          setVpnOpen(false);
          await load();
        }}
        onCancel={() => setVpnOpen(false)}
        footer={(_, { OkBtn, CancelBtn }) => (
          <>
            <Button
              danger
              onClick={async () => {
                try {
                  await apiDelete(`/admin/nodes/${current!.id}/vpn`);
                  message.success("已清除 OpenVPN 配置");
                  setVpnOpen(false);
                  await load();
                } catch (e) {
                  message.error(String(e));
                }
              }}
            >
              清除 VPN
            </Button>
            <CancelBtn />
            <OkBtn />
          </>
        )}
      >
        <Typography.Paragraph type="secondary">
          转发节点作为 OpenVPN <strong>客户端</strong> 连接 VyOS 骨干；保存后 Agent 自动写密钥/证书与配置并重启
          <code> openvpn@gfc-backbone</code>。VyOS 服务端需在路由器上手工应用（可点「导出 VyOS 配置」参考）。
          VyOS 1.2 推荐使用 <strong>Static Key</strong> 模式；PKI 证书模式适合需要 CA 管理的场景。
        </Typography.Paragraph>
        <Space style={{ marginBottom: 16 }} wrap>
          <Button
            loading={pkiLoading}
            onClick={async () => {
              setPkiLoading(true);
              try {
                const res = await apiPost<Record<string, unknown>>(
                  `/admin/nodes/${current!.id}/vpn/pki`,
                  { save: true, common_name: `gfc-node-${current!.id}` }
                );
                message.success(`已签发并保存客户端证书 CN=${res.commonName}`);
                await openVpnModal(current!);
              } catch (e) {
                message.error(String(e));
              } finally {
                setPkiLoading(false);
              }
            }}
          >
            生成客户端证书 (PKI)
          </Button>
          <Button
            loading={staticKeyLoading}
            onClick={async () => {
              setStaticKeyLoading(true);
              try {
                await apiPost(`/admin/nodes/${current!.id}/vpn/static-key`, { save: true });
                message.success("已生成并保存 Static Key，请将同一密钥上传到 VyOS");
                await openVpnModal(current!);
              } catch (e) {
                message.error(String(e));
              } finally {
                setStaticKeyLoading(false);
              }
            }}
          >
            生成 Static Key
          </Button>
          <Button
            onClick={async () => {
              try {
                const res = await apiGet<{ config: string }>(
                  `/admin/nodes/${current!.id}/vpn/vyos`
                );
                setVyosText(res.config);
                setVyosOpen(true);
              } catch (e) {
                message.error(String(e));
              }
            }}
          >
            导出 VyOS 配置
          </Button>
        </Space>
        <Form
          form={vpnForm}
          layout="vertical"
          initialValues={{
            authMode: "pki",
            port: 1194,
            proto: "udp",
            dev: "tun0",
            tunnelNetwork: "",
            autoStaticRoutes: true,
            remoteNetworks: [""],
          }}
        >
          <Form.Item name="authMode" label="认证方式">
            <Select
              options={[
                { value: "pki", label: "PKI 证书 (CA + 客户端证书)" },
                { value: "static_key", label: "Static Key (VyOS 1.2 预共享密钥)" },
              ]}
              style={{ width: 320 }}
            />
          </Form.Item>
          <Form.Item name="remote" label="VyOS 公网地址 (remote)" rules={[{ required: true }]}>
            <Input placeholder="203.0.0.1" />
          </Form.Item>
          <Space wrap>
            <Form.Item name="port" label="端口">
              <InputNumber min={1} max={65535} />
            </Form.Item>
            <Form.Item name="proto" label="协议">
              <Select options={[{ value: "udp" }, { value: "tcp" }]} style={{ width: 100 }} />
            </Form.Item>
            <Form.Item name="dev" label="隧道接口 (TPROXY 入口)">
              <Input placeholder="tun0" style={{ width: 100 }} />
            </Form.Item>
            <Form.Item
              name="tunnelNetwork"
              label="隧道网段 (VyOS 导出用)"
              extra="留空保存时自动从 10.255.0.0/16 池分配 /30，并规避与其他节点/线路网段冲突"
            >
              <Space>
                <Input placeholder="留空自动分配" style={{ width: 160 }} />
                <Button
                  onClick={() => void suggestTunnelNetwork(current!.id).catch((e) => message.error(String(e)))}
                >
                  自动分配
                </Button>
              </Space>
            </Form.Item>
          </Space>
          <Form.Item name="autoStaticRoutes" valuePropName="checked">
            <Checkbox>自动生成回程静态路由（线路 source_cidrs + 下方网段，经 tun0）</Checkbox>
          </Form.Item>
          <Form.Item label="骨干/客户网段 (remote_networks)">
            <Form.List name="remoteNetworks">
              {(fields, { add, remove }) => (
                <>
                  {fields.map(({ key, name, ...rest }) => (
                    <Space key={key} align="baseline" style={{ display: "flex", marginBottom: 8 }}>
                      <Form.Item {...rest} name={name} style={{ flex: 1, marginBottom: 0 }}>
                        <Input placeholder="10.10.10.0/30" />
                      </Form.Item>
                      <MinusCircleOutlined onClick={() => remove(name)} />
                    </Space>
                  ))}
                  <Button type="dashed" onClick={() => add()} block icon={<PlusIcon />}>
                    添加网段
                  </Button>
                </>
              )}
            </Form.List>
          </Form.Item>
          <Form.Item noStyle shouldUpdate={(prev, cur) => prev.authMode !== cur.authMode}>
            {({ getFieldValue }) =>
              getFieldValue("authMode") === "static_key" ? (
                <Form.Item
                  name="staticKey"
                  label="OpenVPN Static Key"
                  rules={[{ required: true, message: "请填写或点击「生成 Static Key」" }]}
                  extra="与 VyOS 侧 shared-secret-key-file 使用同一密钥文件内容"
                >
                  <Input.TextArea rows={6} placeholder="-----BEGIN OpenVPN Static key V1-----" />
                </Form.Item>
              ) : (
                <>
                  <Form.Item name="ca" label="CA 证书 (PEM)" rules={[{ required: true }]}>
                    <Input.TextArea rows={3} />
                  </Form.Item>
                  <Form.Item name="cert" label="客户端证书 (PEM)" rules={[{ required: true }]}>
                    <Input.TextArea rows={3} />
                  </Form.Item>
                  <Form.Item name="key" label="客户端私钥 (PEM)" rules={[{ required: true }]}>
                    <Input.TextArea rows={3} />
                  </Form.Item>
                  <Form.Item name="tlsAuth" label="tls-auth (可选)">
                    <Input.TextArea rows={2} />
                  </Form.Item>
                </>
              )
            }
          </Form.Item>
          <Form.Item name="extraConfig" label="额外 openvpn 指令">
            <Input.TextArea rows={2} placeholder="例: route-nopull" />
          </Form.Item>
        </Form>
      </Modal>

      <Modal
        title={`VyOS 参考配置 — ${current?.name}`}
        open={vyosOpen}
        width={720}
        onCancel={() => setVyosOpen(false)}
        footer={[
          <Button key="close" onClick={() => setVyosOpen(false)}>
            关闭
          </Button>,
          <Button
            key="copy"
            type="primary"
            onClick={() => {
              void navigator.clipboard.writeText(vyosText);
              message.success("已复制");
            }}
          >
            复制
          </Button>,
        ]}
      >
        <Typography.Paragraph type="secondary">
          以下为根据当前节点与线路生成的 VyOS CLI 参考，需在骨干路由器上手工调整证书路径后 commit。
        </Typography.Paragraph>
        <Input.TextArea value={vyosText} rows={18} readOnly style={{ fontFamily: "monospace" }} />
      </Modal>
    </div>
  );
}
