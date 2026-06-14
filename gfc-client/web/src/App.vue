<script setup lang="ts">
import { computed } from 'vue'
import { useRoute } from 'vue-router'

const route = useRoute()
const flashHref = computed(() => `http://${window.location.hostname}/flash.html`)
const nav = [
  { to: '/', label: '概览' },
  { to: '/nodes', label: '节点' },
  { to: '/policy', label: '策略组' },
  { to: '/singbox', label: 'Sing-box' },
  { to: '/dns', label: 'DNS' },
  { to: '/rules', label: '分流规则' },
  { to: '/network', label: '网络' },
  { to: '/services', label: '服务' },
  { to: '/logs', label: '日志' },
  { to: '/settings', label: '设置' },
]
</script>

<template>
  <div v-if="route.path === '/flash.html'" class="flash-only">
    <router-view />
  </div>
  <div v-else class="layout">
    <aside class="sidebar">
      <div class="brand">GFC Client</div>
      <nav>
        <router-link v-for="item in nav" :key="item.to" :to="item.to">{{ item.label }}</router-link>
      </nav>
      <a class="flash-link" :href="flashHref" target="_blank">刷码页 (端口 80)</a>
    </aside>
    <main class="content">
      <router-view />
    </main>
  </div>
</template>
