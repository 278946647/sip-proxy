/**
 * Copy text to clipboard. Works on HTTP (no navigator.clipboard) and older browsers.
 */
export async function copyToClipboard(text: string): Promise<void> {
  const value = text.trim();
  if (!value) {
    throw new Error("没有可复制的内容");
  }

  if (typeof navigator !== "undefined" && navigator.clipboard?.writeText) {
    try {
      await navigator.clipboard.writeText(value);
      return;
    } catch {
      // fall through to legacy copy
    }
  }

  const ta = document.createElement("textarea");
  ta.value = value;
  ta.setAttribute("readonly", "");
  ta.style.position = "fixed";
  ta.style.left = "-9999px";
  ta.style.top = "0";
  document.body.appendChild(ta);
  ta.focus();
  ta.select();
  try {
    const ok = document.execCommand("copy");
    if (!ok) {
      throw new Error("浏览器不支持自动复制，请手动全选复制");
    }
  } finally {
    document.body.removeChild(ta);
  }
}
