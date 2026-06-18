<template>
  <div class="wrap">
    <div class="card">
      <h1>404</h1>
      <p>页面不存在或没有权限访问。</p>
      <router-link to="/overview/dashboard">返回概览</router-link>
    </div>
  </div>
</template>

<style scoped>
.wrap {
  height: 100%;
  display: grid;
  place-items: center;
}

.card {
  padding: 20px;
  border: 1px solid var(--border);
  border-radius: 10px;
  background: var(--panel);
}

h1 {
  margin: 0;
}

p {
  color: var(--muted);
}

a {
  color: var(--brand);
}
</style>
