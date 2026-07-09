import { ensureRemoteSession } from "../lib/reverseSsh";
import { absoluteUrl, openFixedPopup } from "../lib/openPopup";
import { message } from "antd";

const POPUP_SIZE: Record<"ssh" | "web" | "flash", { w: number; h: number }> = {
  ssh: { w: 920, h: 620 },
  web: { w: 1280, h: 800 },
  flash: { w: 1100, h: 760 },
};

function withToken(url: string, token: string): string {
  const sep = url.includes("?") ? "&" : "?";
  return `${url}${sep}token=${encodeURIComponent(token)}`;
}

function openRemoteWindow(
  target: "ssh" | "web" | "flash",
  deviceId: number,
  url: string
): void {
  const { w, h } = POPUP_SIZE[target];
  const name = `gfc-remote-${target}-${deviceId}`;
  const win = openFixedPopup(url, name, w, h);
  if (!win) {
    message.warning("浏览器拦截了弹出窗口，请允许本站弹窗后重试");
  }
}

export async function openRemoteTarget(
  deviceId: number,
  target: "ssh" | "web" | "flash",
  deviceName: string
) {
  const hide = message.loading(`正在连接设备「${deviceName}」…`, 0);
  try {
    const session = await ensureRemoteSession(deviceId);
    hide();
    const token = localStorage.getItem("gfc_token") || "";
    if (target === "ssh") {
      openRemoteWindow(
        "ssh",
        deviceId,
        absoluteUrl(withToken(`/client-devices/${deviceId}/ssh`, token))
      );
      return;
    }
    const path = target === "web" ? session.urls.web : session.urls.flash;
    if (!path) {
      message.error("反代 URL 不可用");
      return;
    }
    openRemoteWindow(target, deviceId, absoluteUrl(withToken(path, token)));
  } catch (e) {
    hide();
    message.error(String(e));
  }
}
