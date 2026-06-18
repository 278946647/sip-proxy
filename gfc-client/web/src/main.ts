import { createApp } from 'vue'
import { createPinia } from 'pinia'
import App from './App.vue'
import router, { setupRouterGuards } from './router'
import { vAuth } from '@/directives/auth'
import './styles/index.css'

const app = createApp(App)
const pinia = createPinia()

app.use(pinia)
app.use(router)
app.directive('auth', vAuth)
setupRouterGuards(router, pinia)

app.mount('#app')
