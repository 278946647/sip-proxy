<template>
  <footer class="footer">
    <span>设备管理后台 · 低性能模式</span>
    <span class="dot" />
    <span>Agent: online</span>
  </footer>
</template>

<style scoped>
.footer {
  padding: 10px 16px;
  border-top: 1px solid var(--border);
  background: var(--panel);
  color: var(--muted);
  display: flex;
  align-items: center;
  gap: 8px;
  font-size: 12px;
}

.dot {
  width: 7px;
  height: 7px;
  border-radius: 999px;
  background: var(--ok);
}
</style>
