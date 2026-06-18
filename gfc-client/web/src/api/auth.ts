import type { Pinia } from 'pinia'
import { getToken, removeToken, setToken } from '@/utils/auth'
import { useUserStore } from '@/store/modules/user'

export const authApi = {
  isLoggedIn: () => Boolean(getToken()),
  loginByToken: async (token: string, pinia: Pinia) => {
    setToken(token)
    const userStore = useUserStore(pinia)
    await userStore.bootstrap()
  },
  logout: (pinia: Pinia) => {
    removeToken()
    useUserStore(pinia).reset()
  },
}
