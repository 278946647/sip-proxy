<script setup lang="ts">
import { computed } from 'vue'
import { useRoute } from 'vue-router'
import { usePermissionStore } from '@/store/modules/permission'
import Sidebar from './components/Sidebar.vue'
import HeaderBar from './components/HeaderBar.vue'
import FooterStatus from './components/FooterStatus.vue'

const route = useRoute()
const permissionStore = usePermissionStore()

const title = computed(() => (route.meta.title as string) || 'GFC Client')
</script>

<template>
  <div class="layout-shell">
    <Sidebar :menus="permissionStore.menus" />
    <div class="layout-main">
      <HeaderBar :title="title" />
      <main class="layout-content">
        <router-view />
      </main>
      <FooterStatus />
    </div>
  </div>
</template>

<style scoped>
.layout-shell {
  display: flex;
  min-height: 100%;
}

.layout-main {
  display: flex;
  flex-direction: column;
  min-width: 0;
  flex: 1;
}

.layout-content {
  padding: 16px;
  overflow: auto;
  min-height: 0;
  flex: 1;
}
</style>
