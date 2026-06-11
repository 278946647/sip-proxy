import {
  Button,
  Form,
  Input,
  Modal,
  Popconfirm,
  Space,
  Statistic,
  Table,
  Tag,
  Typography,
  message,
} from "antd";
import { PlusOutlined } from "@ant-design/icons";
import { useEffect, useMemo, useState } from "react";
import dayjs from "dayjs";
import { apiDelete, apiGet, apiPost, apiPatch } from "../api/client";
import { mapSocks, type SocksProfile } from "../types";
import { formatSocksAddress } from "../utils/socksAddress";

export function ProxiesPage() {
  const [rows, setRows] = useState<SocksProfile[]>([]);
  const [open, setOpen] = useState(false);
  const [editing, setEditing] = useState<SocksProfile | null>(null);
  const [form] = Form.useForm();

  const load = async () => {
    const s = await apiGet<Record<string, unknown>[]>("/admin/socks");
    setRows(s.map(mapSocks));
  };

  useEffect(() => {
    void load().catch((e) => message.error(String(e)));
  }, []);

  const stats = useMemo(() => {
    const online = rows.filter((r) => r.isHealthy).length;
    return { total: rows.length, online, offline: rows.length - online };
  }, [rows]);

  const submit = async () => {
    const v = await form.validateFields();
    try {
      const common = {
        name: v.name as string,
        country: (v.country as string) || null,
        channel: (v.channel as string) || null,
        remark: (v.remark as string) || null,
      };
      if (editing) {
        const body: Record<string, unknown> = { ...common };
        if (v.address) body.address = v.address;
        await apiPatch(`/admin/socks/${editing.id}`, body);
        message.success("已更新");
      } else {
        await apiPost("/admin/socks", {
          ...common,
          address: v.address as string,
        });
        message.success("已创建");
      }
      setOpen(false);
      setEditing(null);
      form.resetFields();
      await load();
    } catch (e) {
      message.error(String(e));
    }
  };

  return (
    <div>
      <div style={{ display: "flex", justifyContent: "space-between", marginBottom: 16 }}>
        <Typography.Title level={4} style={{ margin: 0 }}>
          Socks5 代理配置
        </Typography.Title>
        <Button
          type="primary"
          icon={<PlusOutlined />}
          onClick={() => {
            setEditing(null);
            form.resetFields();
            setOpen(true);
          }}
        >
          添加代理
        </Button>
      </div>

      <Space size="large" style={{ marginBottom: 16 }}>
        <Statistic title="总计" value={stats.total} />
        <Statistic title="正常" value={stats.online} valueStyle={{ color: "#3f8600" }} />
        <Statistic title="异常" value={stats.offline} valueStyle={{ color: "#cf1322" }} />
      </Space>

      <Table
        rowKey="id"
        dataSource={rows}
        columns={[
          { title: "#", dataIndex: "id", width: 56 },
          {
            title: "地址",
            dataIndex: "addressDisplay",
            render: (_, r) => (
              <Typography.Text copyable code>
                {r.addressDisplay || formatSocksAddress(r.host, r.port, r.username, r.password)}
              </Typography.Text>
            ),
          },
          { title: "标签", dataIndex: "name" },
          { title: "国家", dataIndex: "country", render: (v) => v || "-" },
          { title: "渠道", dataIndex: "channel", render: (v) => v || "-" },
          {
            title: "状态",
            dataIndex: "isHealthy",
            render: (v: boolean) =>
              v ? <Tag color="green">在线</Tag> : <Tag color="red">离线</Tag>,
          },
          { title: "备注", dataIndex: "remark", ellipsis: true },
          {
            title: "创建时间",
            dataIndex: "createdAt",
            render: (v) => (v ? dayjs(v).format("YYYY-MM-DD HH:mm:ss") : "-"),
          },
          {
            title: "操作",
            render: (_, r) => (
              <>
                <Button
                  type="link"
                  onClick={async () => {
                    try {
                      const res = await apiPost<{ ok: boolean; detail: string }>(
                        `/admin/socks/${r.id}/probe`,
                        {}
                      );
                      message[res.ok ? "success" : "error"](
                        res.ok ? `在线：${res.detail}` : `离线：${res.detail}`
                      );
                      await load();
                    } catch (e) {
                      message.error(String(e));
                    }
                  }}
                >
                  检测
                </Button>
                <Button
                  type="link"
                  onClick={() => {
                    setEditing(r);
                    form.setFieldsValue({
                      name: r.name,
                      address: r.addressDisplay,
                      country: r.country,
                      channel: r.channel,
                      remark: r.remark,
                    });
                    setOpen(true);
                  }}
                >
                  编辑
                </Button>
                <Popconfirm
                  title="确认删除？"
                  onConfirm={async () => {
                    await apiDelete(`/admin/socks/${r.id}`);
                    message.success("已删除");
                    await load();
                  }}
                >
                  <Button type="link" danger>
                    删除
                  </Button>
                </Popconfirm>
              </>
            ),
          },
        ]}
      />

      <Modal
        title={editing ? "编辑 Socks5 代理" : "添加 Socks5 代理"}
        open={open}
        onOk={() => void submit()}
        onCancel={() => setOpen(false)}
        destroyOnClose
        width={560}
      >
        <Form form={form} layout="vertical">
          <Form.Item
            name="address"
            label="代理地址"
            rules={[{ required: !editing, message: "请填写代理地址" }]}
            extra="格式: username:password@IP:Port（无认证: host:port）"
          >
            <Input placeholder="username:password@103.129.196.241:9473" />
          </Form.Item>
          <Form.Item name="name" label="标签" rules={[{ required: true }]}>
            <Input placeholder="如 momoproxy" />
          </Form.Item>
          <Form.Item name="country" label="国家">
            <Input placeholder="可选，如 马来西亚" />
          </Form.Item>
          <Form.Item name="channel" label="渠道">
            <Input placeholder="可选，如 上海-集萃" />
          </Form.Item>
          <Form.Item name="remark" label="备注">
            <Input.TextArea rows={2} />
          </Form.Item>
        </Form>
      </Modal>
    </div>
  );
}
