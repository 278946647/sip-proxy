import { Input, Modal, Typography, message } from "antd";
import { createElement } from "react";

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
  onConfirm: () => Promise<void>,
  opts?: { boundDeviceName?: string | null }
) {
  if (opts?.boundDeviceName) {
    Modal.warning({
      title: `无法删除线路 ${tid}`,
      content: `线路仍绑定客户端「${opts.boundDeviceName}」，请先在客户端管理中解绑后再删除。`,
      okText: "知道了",
    });
    return;
  }
  Modal.confirm({
    title: `确认删除线路 ${tid}？`,
    content: "将删除线路记录与线路码。请确认该线路未绑定任何客户端。此操作不可恢复。",
    okText: "确认删除",
    okButtonProps: { danger: true },
    cancelText: "取消",
    onOk: onConfirm,
  });
}

/** Soft factory reset — clear line code, unbind, keep platform custody. */
export function confirmSoftFactoryReset(
  deviceName: string,
  confirmToken: string,
  onConfirm: () => Promise<void>
) {
  const token = (confirmToken || deviceName).trim();
  let typed = "";

  Modal.confirm({
    title: `确认对设备「${deviceName}」执行软恢复出厂？`,
    width: 520,
    content: createElement(
      "div",
      null,
      createElement(
        Typography.Paragraph,
        null,
        `将对设备 ${deviceName} 执行恢复出厂：`
      ),
      createElement(
        "ul",
        { style: { paddingLeft: 20, marginBottom: 12 } },
        createElement("li", null, "清除设备上的线路码"),
        createElement("li", null, "解除线路绑定，切换直连"),
        createElement("li", null, "设备保持平台托管（远程管理仍可用）"),
        createElement("li", null, "重新分配线路请在平台操作，无需刷码")
      ),
      createElement(
        Typography.Paragraph,
        { type: "secondary" },
        "此操作不可撤销，需输入设备名称或 TID 确认。"
      ),
      createElement(Input, {
        placeholder: `请输入「${token}」确认`,
        onChange: (e: { target: { value: string } }) => {
          typed = e.target.value;
        },
        style: { marginTop: 8 },
      })
    ),
    okText: "确认软恢复",
    okButtonProps: { danger: true },
    cancelText: "取消",
    onOk: async () => {
      if (typed.trim() !== token) {
        message.error(`请输入「${token}」以确认`);
        return Promise.reject();
      }
      await onConfirm();
    },
  });
}

/** Hard retire (replaces plain delete) — requires prior soft factory reset. */
export function confirmHardRetire(
  deviceName: string,
  onConfirm: () => Promise<void>,
  opts?: { codeCleared?: boolean; lineBound?: boolean }
) {
  if (opts?.lineBound || !opts?.codeCleared) {
    Modal.warning({
      title: "无法硬退库",
      content:
        "硬退库前必须先执行「软恢复出厂」（解除线路绑定并清除线路码）。硬退库后平台不再管控该设备，同 MAC 须管理员重新认领方可入库。",
      okText: "知道了",
    });
    return;
  }
  Modal.confirm({
    title: `硬退库「${deviceName}」？`,
    width: 520,
    content:
      "将退出平台管控：撤销 Token、写入退库记录、释放远程端口（进入冷却期）。\n\n" +
      "设备将无法自动重新注册；同 MAC 须管理员在「已退库」中重新认领。\n\n" +
      "防硬件丢失场景请勿使用此操作。此操作不可恢复。",
    okText: "确认硬退库",
    okButtonProps: { danger: true },
    cancelText: "取消",
    onOk: onConfirm,
  });
}

/** @deprecated use confirmHardRetire */
export function confirmDeleteClientDevice(
  name: string,
  onConfirm: () => Promise<void>
) {
  confirmHardRetire(name, onConfirm, { codeCleared: true, lineBound: false });
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

export function confirmDeleteUser(username: string, onConfirm: () => Promise<void>) {
  Modal.confirm({
    title: `删除用户「${username}」？`,
    content: "删除后该账号无法登录，操作不可恢复。超级管理员不可删除，只能禁用。",
    okText: "确认删除",
    okButtonProps: { danger: true },
    cancelText: "取消",
    onOk: onConfirm,
  });
}
