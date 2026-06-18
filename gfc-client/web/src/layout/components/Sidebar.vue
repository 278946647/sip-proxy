<script setup lang="ts">
import type { MenuItem } from '@/router/types'

defineProps<{ menus: MenuItem[] }>()
</script>

<template>
  <aside class="sidebar">
    <div class="brand">GFC Client</div>
    <nav class="nav-tree">
      <div v-for="group in menus" :key="group.path" class="nav-group">
        <router-link class="nav-link nav-parent" :to="group.path">{{ group.title }}</router-link>
        <template v-if="group.children?.length">
          <router-link
            v-for="item in group.children"
            :key="`${group.path}-${item.path}`"
            class="nav-link nav-child"
            :to="`${group.path}/${item.path}`"
          >
            {{ item.title }}
          </router-link>
        </template>
      </div>
    </nav>
  </aside>
</template>

<style scoped>
.sidebar {
  width: 250px;
  background: #111827;
  color: #e5e7eb;
  border-right: 1px solid #1f2937;
  overflow: auto;
}

.brand {
  padding: 14px 16px;
  font-size: 15px;
  font-weight: 700;
  border-bottom: 1px solid #1f2937;
}

.nav-tree {
  padding: 8px;
}

.nav-group {
  margin-bottom: 10px;
}

.nav-link {
  display: block;
  border-radius: 6px;
}

.nav-parent {
  font-weight: 600;
  padding: 8px 10px;
}

.nav-child {
  margin-top: 4px;
  margin-left: 10px;
  font-size: 13px;
  color: #cbd5e1;
  padding: 6px 8px;
}

.router-link-active {
  background: #1d4ed8;
  color: #fff;
}
</style>
