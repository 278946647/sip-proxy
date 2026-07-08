import { Modal } from "antd";

export function confirmLineEnableChange(
  checked: boolean,
  tid: string,
  onConfirm: () => Promise<void>
) {
  Modal.confirm({
    title: checked ? `确认启用线路 ${tid}？` : `确认禁用线路 ${tid}？`,
    content: checked
      ? "启用后，绑定客户端将在下次拉取配置后恢复代理。"
      : "禁用后，绑定客户端将切换为直连模式，设备仍可在线管控。",
    okText: "确认",
    cancelText: "取消",
    onOk: onConfirm,
  });
}
