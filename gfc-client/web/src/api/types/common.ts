export interface ApiError {
  message: string
  code?: string
}

export interface ApiResponse<T> {
  ok: boolean
  data: T
  error?: ApiError
}

export interface OptionItem {
  label: string
  value: string
}
