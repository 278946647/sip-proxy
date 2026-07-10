import { Modal } from "antd";

export function confirmClientLineChange(
  deviceName: string,
  fromLabel: string,
  toLabel: string,
  onConfirm: () => Promise<void>
) {
  Modal.confirm({
    title: "确认更换关联线路？",
    content: `设备「${deviceName}」\n当前：${fromLabel}\n目标：${toLabel}\n\n客户端将在下次拉取配置后切换出口，期间可能短暂中断。`,
    okText: "确认更换",
    cancelText: "取消",
    onOk: onConfirm,
  });
}

export function confirmClientLineUnbind(
  deviceName: string,
  fromLabel: string,
  onConfirm: () => Promise<void>
) {
  Modal.confirm({
    title: "确认解绑线路？",
    content: `设备「${deviceName}」将解除与「${fromLabel}」的关联。\n\n解绑后将切换为直连模式，设备仍可在线管控。`,
    okText: "确认解绑",
    okButtonProps: { danger: true },
    cancelText: "取消",
    onOk: onConfirm,
  });
}

export function confirmProxyModeChange(
  deviceName: string,
  fromLabel: string,
  toLabel: string,
  onConfirm: () => Promise<void>
) {
  Modal.confirm({
    title: "确认切换路由模式？",
    content: `设备「${deviceName}」\n当前：${fromLabel}\n目标：${toLabel}\n\n客户端将在下次拉取配置后应用新的路由工作模式。`,
    okText: "确认切换",
    cancelText: "取消",
    onOk: onConfirm,
  });
}

export function confirmRoutingSchemeChange(
  deviceName: string,
  fromLabel: string,
  toLabel: string,
  onConfirm: () => Promise<void>
) {
  Modal.confirm({
    title: "确认切换代理模式？",
    content: `设备「${deviceName}」\n当前：${fromLabel}\n目标：${toLabel}\n\n客户端将在下次拉取配置后切换流量分流策略。`,
    okText: "确认切换",
    cancelText: "取消",
    onOk: onConfirm,
  });
}
