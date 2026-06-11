import { Button, Form, Input, Modal, Select, Table, Tag, Typography, message } from "antd";
import { PlusOutlined } from "@ant-design/icons";
import { useEffect, useState } from "react";
import dayjs from "dayjs";
import { getUser } from "../api/auth";
import { apiGet, apiPatch, apiPost } from "../api/client";
import type { PlatformUser } from "../types";

export function UsersPage() {
  const [users, setUsers] = useState<PlatformUser[]>([]);
  const [open, setOpen] = useState(false);
  const [resetOpen, setResetOpen] = useState(false);
  const [current, setCurrent] = useState<PlatformUser | null>(null);
  const [form] = Form.useForm();
  const [resetForm] = Form.useForm();
  const me = getUser();
  const isAdmin = me?.role === "admin";

  const load = async () => {
    const u = await apiGet<Record<string, unknown>[]>("/admin/users");
    setUsers(
      u.map((x) => ({
        id: x.id as number,
        username: x.username as string,
        role: x.role as string,
        isActive: x.is_active as boolean,
        createdAt: x.created_at as string,
      }))
    );
  };

  useEffect(() => {
    void load().catch((e) => message.error(String(e)));
  }, []);

  return (
    <div>
      <div style={{ display: "flex", justifyContent: "space-between", marginBottom: 16 }}>
        <Typography.Title level={4} style={{ margin: 0 }}>
          用户管理
        </Typography.Title>
        {isAdmin && (
          <Button type="primary" icon={<PlusOutlined />} onClick={() => setOpen(true)}>
            添加用户
          </Button>
        )}
      </div>
      <Table
        rowKey="id"
        dataSource={users}
        columns={[
          { title: "用户名", dataIndex: "username" },
          {
            title: "角色",
            dataIndex: "role",
            render: (r: string) => <Tag color={r === "admin" ? "blue" : "default"}>{r}</Tag>,
          },
          {
            title: "状态",
            dataIndex: "isActive",
            render: (v: boolean) => (v ? <Tag color="green">启用</Tag> : <Tag>禁用</Tag>),
          },
          {
            title: "创建时间",
            dataIndex: "createdAt",
            render: (v) => dayjs(v).format("YYYY-MM-DD HH:mm"),
          },
          ...(isAdmin
            ? [
                {
                  title: "操作",
                  render: (_: unknown, r: PlatformUser) => (
                    <Button
                      type="link"
                      onClick={() => {
                        setCurrent(r);
                        resetForm.resetFields();
                        setResetOpen(true);
                      }}
                    >
                      重置密码
                    </Button>
                  ),
                },
              ]
            : []),
        ]}
      />
      <Modal
        title="添加用户"
        open={open}
        onOk={async () => {
          const v = await form.validateFields();
          await apiPost("/admin/users", v);
          message.success("已创建");
          setOpen(false);
          form.resetFields();
          await load();
        }}
        onCancel={() => setOpen(false)}
      >
        <Form form={form} layout="vertical">
          <Form.Item name="username" label="用户名" rules={[{ required: true }]}>
            <Input />
          </Form.Item>
          <Form.Item
            name="password"
            label="密码"
            rules={[{ required: true, min: 6, message: "至少 6 位" }]}
          >
            <Input.Password />
          </Form.Item>
          <Form.Item name="role" label="角色" initialValue="operator">
            <Select
              options={[
                { label: "管理员", value: "admin" },
                { label: "运维", value: "operator" },
                { label: "只读", value: "readonly" },
              ]}
            />
          </Form.Item>
        </Form>
      </Modal>
      <Modal
        title={`重置密码 — ${current?.username}`}
        open={resetOpen}
        onOk={async () => {
          const v = await resetForm.validateFields();
          await apiPatch(`/admin/users/${current!.id}`, { password: v.password });
          message.success("密码已重置");
          setResetOpen(false);
        }}
        onCancel={() => setResetOpen(false)}
      >
        <Form form={resetForm} layout="vertical">
          <Form.Item
            name="password"
            label="新密码"
            rules={[{ required: true, min: 6, message: "至少 6 位" }]}
          >
            <Input.Password />
          </Form.Item>
        </Form>
      </Modal>
    </div>
  );
}
