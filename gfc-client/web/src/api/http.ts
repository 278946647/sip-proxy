import axios from 'axios'
import { getToken } from '@/utils/auth'
import type { ApiResponse } from './types/common'

const http = axios.create({
  baseURL: '/api/v1',
  timeout: 12000,
})

http.interceptors.request.use((config) => {
  const token = getToken()
  if (token) {
    config.headers['X-GFC-Token'] = token
  }
  return config
})

http.interceptors.response.use((response) => response.data)

export async function get<T>(url: string, params?: Record<string, unknown>) {
  return http.get<never, ApiResponse<T>>(url, { params })
}

export async function post<T>(url: string, data?: unknown) {
  return http.post<never, ApiResponse<T>>(url, data)
}

export async function put<T>(url: string, data?: unknown) {
  return http.put<never, ApiResponse<T>>(url, data)
}

export async function del<T>(url: string) {
  return http.delete<never, ApiResponse<T>>(url)
}
