import { onBeforeUnmount, onMounted } from 'vue'

export function usePolling(task: () => Promise<void>, intervalMs = 15000) {
  let timer: number | undefined

  const run = async () => {
    await task()
  }

  onMounted(async () => {
    await run()
    timer = window.setInterval(run, intervalMs)
  })

  onBeforeUnmount(() => {
    if (timer) {
      window.clearInterval(timer)
    }
  })
}
