import type { Directive } from 'vue'
import { useUserStore } from '@/store/modules/user'

export const vAuth: Directive<HTMLElement, string> = {
  mounted(el, binding) {
    const userStore = useUserStore()
    const code = binding.value
    if (!code) return
    if (!userStore.permissions.includes(code)) {
      el.style.display = 'none'
    }
  },
}
