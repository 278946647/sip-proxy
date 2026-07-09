import { startReverseSession, waitForTunnel } from "../lib/reverseSsh";
import { message } from "antd";

export async function openRemoteTarget(
  deviceId: number,
  target: "ssh" | "web" | "flash",
  deviceName: string
) {
  const hide = message.loading(`正在请求设备「${deviceName}」建立远程隧道…`, 0);
  try {
    await startReverseSession(deviceId, [target]);
    const session = await waitForTunnel(deviceId);
    hide();
    if (target === "ssh") {
      window.open(`/client-devices/${deviceId}/ssh`, "_blank");
      return;
    }
    const url = target === "web" ? session.urls.web : session.urls.flash;
    if (!url) {
      message.error("反代 URL 不可用");
      return;
    }
    const token = localStorage.getItem("gfc_token") || "";
    const sep = url.includes("?") ? "&" : "?";
    window.open(`${url}${sep}token=${encodeURIComponent(token)}`, "_blank");
  } catch (e) {
    hide();
    message.error(String(e));
  }
}
