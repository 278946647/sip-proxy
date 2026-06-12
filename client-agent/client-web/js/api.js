const API = {
  async get(path) {
    const r = await fetch(path, { cache: "no-store" });
    const data = await r.json();
    if (!r.ok) throw new Error(data.error || `HTTP ${r.status}`);
    return data;
  },

  async post(path, body) {
    const r = await fetch(path, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body || {}),
    });
    const data = await r.json();
    if (!r.ok) throw new Error(data.error || `HTTP ${r.status}`);
    return data;
  },

  status() {
    return this.get("/api/status");
  },

  device() {
    return this.get("/api/device");
  },

  settings() {
    return this.get("/api/settings");
  },

  interfaces() {
    return this.get("/api/interfaces");
  },

  services() {
    return this.get("/api/services");
  },

  logs(service, lines = 200) {
    return this.get(`/api/logs?service=${encodeURIComponent(service)}&lines=${lines}`);
  },

  flashLineCode(code, resetState = true) {
    return this.post("/api/line-code", { code, reset_state: resetState });
  },

  saveSettings(data) {
    return this.post("/api/settings", data);
  },

  restartService(name) {
    return this.post("/api/service/restart", { service: name });
  },
};

function fmtMbps(v) {
  if (v == null || Number.isNaN(v)) return "—";
  return Number(v).toFixed(2);
}

function fmtPct(v) {
  if (v == null) return "—";
  return `${Number(v).toFixed(1)}%`;
}

function fmtMem(used, total) {
  if (!total) return "—";
  return `${used} / ${total} MB`;
}

function statusBadge(online) {
  const cls = online ? "badge-ok" : "badge-off";
  const text = online ? "在线" : "离线";
  return `<span class="badge ${cls}"><span class="badge-dot"></span>${text}</span>`;
}

function serviceBadge(active) {
  const cls = active ? "badge-ok" : "badge-off";
  const text = active ? "运行中" : "已停止";
  return `<span class="badge ${cls}"><span class="badge-dot"></span>${text}</span>`;
}

function showAlert(el, type, message) {
  if (!el) return;
  el.className = `alert alert-${type}`;
  el.textContent = message;
  el.hidden = false;
}

function hideAlert(el) {
  if (el) el.hidden = true;
}

function setActiveNav(page) {
  document.querySelectorAll(".nav a[data-page]").forEach((a) => {
    a.classList.toggle("active", a.dataset.page === page);
  });
}
