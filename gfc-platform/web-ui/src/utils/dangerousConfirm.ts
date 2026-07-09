import { Modal } from "antd";

type RemoteTarget = "ssh" | "web" | "flash";

const REMOTE_COPY: Record<
  RemoteTarget,
  { title: string; content: string }
> = {
  ssh: {
    title: "确认打开远程 SSH？",
    content:
      "将在控制平台与设备之间建立反向 SSH 隧道，并以弹窗打开 root Shell。请确认目标设备无误。",
  },
  web: {
    title: "确认打开 Web 管理？",
    content:
      "将通过反向 HTTP 隧道代理设备 LuCI 界面。会话有效期内占用控制面端口资源。",
  },
  flash: {
    title: "确认打开刷码协助？",
    content:
      "将通过反向 HTTP 隧道打开设备刷码页面，请仅在协助客户激活时使用。",
  },
};

export function confirmRemoteAccess(
  target: RemoteTarget,
  deviceName: string,
  onConfirm: () => void | Promise<void>
) {
  const copy = REMOTE_COPY[target];
  Modal.confirm({
    title: copy.title,
    content: `${copy.content}\n\n目标设备：${deviceName}`,
    okText: "确认连接",
    cancelText: "取消",
    onOk: onConfirm,
  });
}

export function confirmDeleteSocks(name: string, onConfirm: () => Promise<void>) {
  Modal.confirm({
    title: `确认删除 Socks 代理「${name}」？`,
    content: "删除后，引用该代理的线路将无法再通过此出口访问；已下发配置需等待客户端刷新。",
    okText: "确认删除",
    okButtonProps: { danger: true },
    cancelText: "取消",
    onOk: onConfirm,
  });
}

export function confirmDeleteLine(
  tid: string,
  onConfirm: () => Promise<void>
) {
  Modal.confirm({
    title: `确认删除线路 ${tid}？`,
    content:
      "将删除线路记录与线路码；已绑定设备将失去配置关联，需重新刷码或改绑。此操作不可恢复。",
    okText: "确认删除",
    okButtonProps: { danger: true },
    cancelText: "取消",
    onOk: onConfirm,
  });
}

export function confirmDeleteClientDevice(
  name: string,
  onConfirm: () => Promise<void>
) {
  Modal.confirm({
    title: `删除客户端「${name}」？`,
    content:
      "删除后释放远程端口（进入冷却期）；在线设备将自动重新注册。线路码仍有效，可再次刷入。",
    okText: "确认删除",
    okButtonProps: { danger: true },
    cancelText: "取消",
    onOk: onConfirm,
  });
}

export function confirmResetUserPassword(
  username: string,
  onConfirm: () => Promise<void>,
  onCancel?: () => void
) {
  Modal.confirm({
    title: `重置用户「${username}」的密码？`,
    content: "重置后旧密码立即失效；若该用户已登录，其会话将在下次鉴权时失败。",
    okText: "继续重置",
    okButtonProps: { danger: true },
    cancelText: "取消",
    onOk: onConfirm,
    onCancel,
  });
}
