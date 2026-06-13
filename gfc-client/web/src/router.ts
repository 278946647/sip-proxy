import { createRouter, createWebHistory } from 'vue-router'
import Dashboard from './pages/Dashboard.vue'
import Nodes from './pages/Nodes.vue'
import Policy from './pages/Policy.vue'
import DNS from './pages/DNS.vue'
import Rules from './pages/Rules.vue'
import Network from './pages/Network.vue'
import Services from './pages/Services.vue'
import Logs from './pages/Logs.vue'
import Settings from './pages/Settings.vue'
import Flash from './pages/Flash.vue'

const router = createRouter({
  history: createWebHistory(),
  routes: [
    { path: '/', component: Dashboard },
    { path: '/nodes', component: Nodes },
    { path: '/policy', component: Policy },
    { path: '/dns', component: DNS },
    { path: '/rules', component: Rules },
    { path: '/network', component: Network },
    { path: '/services', component: Services },
    { path: '/logs', component: Logs },
    { path: '/settings', component: Settings },
    { path: '/flash.html', component: Flash },
  ],
})

export default router
