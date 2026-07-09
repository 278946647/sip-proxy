/** Open a centered popup with fixed dimensions (non-resizable where supported). */
export function openFixedPopup(
  url: string,
  name: string,
  width = 960,
  height = 640
): Window | null {
  const left = Math.max(0, Math.round((window.screen.availWidth - width) / 2));
  const top = Math.max(0, Math.round((window.screen.availHeight - height) / 2));
  const features = [
    `width=${width}`,
    `height=${height}`,
    `left=${left}`,
    `top=${top}`,
    "menubar=no",
    "toolbar=no",
    "location=yes",
    "status=no",
    "resizable=no",
    "scrollbars=yes",
  ].join(",");
  return window.open(url, name, features);
}

export function absoluteUrl(path: string): string {
  if (/^https?:\/\//i.test(path)) return path;
  return `${window.location.origin}${path.startsWith("/") ? path : `/${path}`}`;
}
