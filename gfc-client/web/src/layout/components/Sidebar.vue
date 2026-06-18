<script setup lang="ts">
import { ref, watch } from 'vue'
import { useRoute } from 'vue-router'
import type { MenuItem } from '@/router/types'

const props = defineProps<{ menus: MenuItem[] }>()
const route = useRoute()
const collapsed = ref(false)
const openGroups = ref<Record<string, boolean>>({})

function isGroupActive(group: MenuItem) {
  return route.path === group.path || route.path.startsWith(`${group.path}/`)
}

function toggleGroup(path: string) {
  openGroups.value[path] = !openGroups.value[path]
}

function isOpen(group: MenuItem) {
  return openGroups.value[group.path] ?? isGroupActive(group)
}

watch(
  () => [props.menus, route.path],
  () => {
    for (const group of props.menus) {
      if (isGroupActive(group)) {
        openGroups.value[group.path] = true
      }
    }
  },
  { immediate: true },
)
</script>

<template>
  <aside class="sidebar" :class="{ collapsed }">
    <div class="brand">
      <span v-if="!collapsed">GFC Client</span>
      <span v-else>GFC</span>
      <button class="collapse-btn" @click="collapsed = !collapsed">{{ collapsed ? '>' : '<' }}</button>
    </div>
    <nav class="nav-tree">
      <div v-for="group in menus" :key="group.path" class="nav-group">
        <button
          class="nav-link nav-parent"
          :class="{ active: isGroupActive(group) }"
          @click="group.children?.length ? toggleGroup(group.path) : undefined"
        >
          <span class="nav-text">{{ group.title }}</span>
          <span v-if="group.children?.length && !collapsed" class="chevron">{{ isOpen(group) ? '▾' : '▸' }}</span>
        </button>
        <template v-if="group.children?.length && isOpen(group) && !collapsed">
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
  width: 232px;
  background: #17202b;
  color: #d7dee8;
  border-right: 1px solid #0f172a;
  overflow: auto;
  transition: width .16s ease;
}

.sidebar.collapsed {
  width: 64px;
}

.brand {
  min-height: 52px;
  padding: 12px 10px 12px 14px;
  font-size: 15px;
  font-weight: 700;
  border-bottom: 1px solid #263241;
  display: flex;
  align-items: center;
  justify-content: space-between;
}

.collapse-btn {
  border: 1px solid #334155;
  background: #0f172a;
  color: #cbd5e1;
  border-radius: 4px;
  width: 24px;
  height: 24px;
  cursor: pointer;
}

.nav-tree {
  padding: 6px;
}

.nav-group {
  margin-bottom: 4px;
}

.nav-link {
  width: 100%;
  display: flex;
  align-items: center;
  border-radius: 3px;
  border: 0;
  text-align: left;
  color: inherit;
  background: transparent;
  cursor: pointer;
}

.nav-parent {
  font-weight: 600;
  padding: 9px 10px;
  color: #f1f5f9;
  justify-content: space-between;
}

.nav-child {
  margin-top: 2px;
  margin-left: 8px;
  font-size: 13px;
  color: #cbd5e1;
  padding: 7px 8px 7px 14px;
}

.nav-parent:hover,
.nav-child:hover {
  background: #223042;
}

.nav-parent.active {
  background: #1d4ed8;
}

.router-link-active {
  background: #1d4ed8;
  color: #fff;
}

.collapsed .nav-parent {
  justify-content: center;
  min-height: 38px;
}

.collapsed .nav-text {
  max-width: 44px;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  font-size: 12px;
}
</style>
