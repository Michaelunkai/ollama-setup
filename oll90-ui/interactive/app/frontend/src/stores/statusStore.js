import { create } from 'zustand'

const useStatusStore = create((set) => ({
  gpuName: '',
  gpuUtil: 0,
  vramUsed: 0,
  vramTotal: 0,
  gpuTemp: 0,
  ollamaRunning: false,
  modelLoaded: false,
  modelName: 'qwen3-14b-oll90',
  tokensPerSec: 0,
  connected: false,

  setConnected: (val) => set({ connected: val }),
  setTokensPerSec: (val) => set({ tokensPerSec: val }),

  fetchStatus: async () => {
    try {
      const res = await fetch('/api/status')
      const data = await res.json()
      set({
        gpuName: data.gpu_name || '',
        gpuUtil: data.gpu_util_percent || 0,
        vramUsed: data.vram_used_mb || 0,
        vramTotal: data.vram_total_mb || 0,
        gpuTemp: data.gpu_temp_c || 0,
        ollamaRunning: data.ollama_running,
        modelLoaded: data.model_loaded,
        modelName: data.model_name || 'qwen3.5-oll90',
      })
    } catch (e) {
      // Backend not available
    }
  },
}))

export default useStatusStore
