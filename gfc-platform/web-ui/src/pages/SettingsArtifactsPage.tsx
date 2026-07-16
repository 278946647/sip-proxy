import { ArrowLeftOutlined, UploadOutlined } from "@ant-design/icons";
import {
  Button,
  Form,
  Input,
  Modal,
  Select,
  Space,
  Switch,
  Table,
  Tag,
  Typography,
  Upload,
  message,
} from "antd";
import { useCallback, useEffect, useState } from "react";
import { useNavigate } from "react-router-dom";
import { apiDelete, apiGet, apiPatch } from "../api/client";
import { formatApiTime } from "../utils/datetime";
import { canWrite, permissionsFromUser } from "../utils/permissions";
import { getToken, getUser } from "../api/auth";

type Artifact = {
  id: number;
  version: string;
  arch: string;
  filename: string;
  sha256: string;
  size_bytes: number;
  notes: string | null;
  is_enabled: boolean;
  created_by: string;
  created_at: string;
};

function formatBytes(n: number) {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
  return `${(n / 1024 / 1024).toFixed(1)} MB`;
}

export function SettingsArtifactsPage() {
  const nav = useNavigate();
  const [items, setItems] = useState<Artifact[]>([]);
  const [loading, setLoading] = useState(false);
  const [uploadOpen, setUploadOpen] = useState(false);
  const [uploading, setUploading] = useState(false);
  const [form] = Form.useForm();
  const [fileList, setFileList] = useState<{ originFileObj?: File; name: string }[]>([]);
  const writable = canWrite(getUser());
  const perms = permissionsFromUser(getUser());

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const rows = await apiGet<Artifact[]>("/admin/artifacts");
      setItems(rows);
    } catch (e) {
      message.error(String(e));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  const doUpload = async () => {
    const v = await form.validateFields();
    const file = fileList[0]?.originFileObj;
    if (!file) {
      message.warning("请选择 runtime tar.gz 文件");
      return;
    }
    setUploading(true);
    try {
      const fd = new FormData();
      fd.append("file", file);
      fd.append("version", v.version);
      fd.append("arch", v.arch);
      if (v.notes) fd.append("notes", v.notes);
      const token = getToken();
      const res = await fetch("/api/admin/artifacts", {
        method: "POST",
        headers: token ? { Authorization: `Bearer ${token}` } : {},
        body: fd,
      });
      if (!res.ok) {
        const t = await res.text();
        throw new Error(t || res.statusText);
      }
      message.success("制品已上传");
      setUploadOpen(false);
      form.resetFields();
      setFileList([]);
      await load();
    } catch (e) {
      message.error(String(e));
    } finally {
      setUploading(false);
    }
  };

  return (
    <div>
      <Space style={{ marginBottom: 16 }} wrap>
        <Button icon={<ArrowLeftOutlined />} onClick={() => nav("/settings")}>
          返回系统设置
        </Button>
        {writable ? (
          <Button
            type="primary"
            icon={<UploadOutlined />}
            onClick={() => {
              form.resetFields();
              setFileList([]);
              setUploadOpen(true);
            }}
          >
            上传制品
          </Button>
        ) : null}
        <Button onClick={() => void load()}>刷新</Button>
      </Space>
      <Typography.Title level={4}>升级制品</Typography.Title>
      <Typography.Paragraph type="secondary">
        上传 Ubuntu 侧 <Typography.Text code>pack-runtime.sh</Typography.Text> 产出的{" "}
        <Typography.Text code>.tar.gz</Typography.Text>
        。在客户端详情页选择版本后可单设备下发 OTA。
      </Typography.Paragraph>
      <Table
        rowKey="id"
        loading={loading}
        dataSource={items}
        pagination={{ pageSize: 20 }}
        columns={[
          { title: "版本", dataIndex: "version" },
          {
            title: "架构",
            dataIndex: "arch",
            render: (a: string) => <Tag>{a}</Tag>,
          },
          { title: "文件名", dataIndex: "filename", ellipsis: true },
          {
            title: "大小",
            dataIndex: "size_bytes",
            render: (n: number) => formatBytes(n || 0),
          },
          {
            title: "SHA256",
            dataIndex: "sha256",
            render: (s: string) => (
              <Typography.Text code copyable={{ text: s }}>
                {s.slice(0, 12)}…
              </Typography.Text>
            ),
          },
          {
            title: "状态",
            dataIndex: "is_enabled",
            render: (v: boolean, row) =>
              writable ? (
                <Switch
                  checked={v}
                  size="small"
                  onChange={async (checked) => {
                    try {
                      await apiPatch(`/admin/artifacts/${row.id}`, { is_enabled: checked });
                      message.success(checked ? "已启用" : "已停用");
                      void load();
                    } catch (e) {
                      message.error(String(e));
                    }
                  }}
                />
              ) : (
                <Tag color={v ? "green" : "default"}>{v ? "启用" : "停用"}</Tag>
              ),
          },
          {
            title: "上传时间",
            dataIndex: "created_at",
            render: (t: string) => formatApiTime(t),
          },
          {
            title: "操作",
            render: (_, row) => (
              <Space>
                {perms.canDeleteStructural ? (
                  <Button
                    type="link"
                    danger
                    onClick={() => {
                      Modal.confirm({
                        title: `删除制品 ${row.version}/${row.arch}？`,
                        content: "删除后设备将无法再下载该版本。",
                        okText: "删除",
                        okButtonProps: { danger: true },
                        onOk: async () => {
                          await apiDelete(`/admin/artifacts/${row.id}`);
                          message.success("已删除");
                          void load();
                        },
                      });
                    }}
                  >
                    删除
                  </Button>
                ) : null}
              </Space>
            ),
          },
        ]}
      />

      <Modal
        title="上传 runtime 制品"
        open={uploadOpen}
        onCancel={() => setUploadOpen(false)}
        onOk={() => void doUpload()}
        confirmLoading={uploading}
        okText="上传"
      >
        <Form form={form} layout="vertical" initialValues={{ arch: "amd64" }}>
          <Form.Item label="文件" required>
            <Upload
              beforeUpload={() => false}
              maxCount={1}
              accept=".gz,.tgz,.tar.gz"
              fileList={fileList as never[]}
              onChange={({ fileList: fl }) => setFileList(fl as never[])}
            >
              <Button icon={<UploadOutlined />}>选择 .tar.gz</Button>
            </Upload>
          </Form.Item>
          <Form.Item name="version" label="版本" rules={[{ required: true }]}>
            <Input placeholder="如 git short hash 或 1.2.3" />
          </Form.Item>
          <Form.Item name="arch" label="架构" rules={[{ required: true }]}>
            <Select
              options={[
                { value: "amd64", label: "amd64 (x86_64)" },
                { value: "arm64", label: "arm64 (aarch64)" },
              ]}
            />
          </Form.Item>
          <Form.Item name="notes" label="备注">
            <Input.TextArea rows={2} />
          </Form.Item>
        </Form>
      </Modal>
    </div>
  );
}
