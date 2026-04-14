import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'

export default defineConfig({
  plugins: [react(), tailwindcss()],
  server: {
    port: 3090,
    allowedHosts: true,
    proxy: {
      '/api': 'http://localhost:8090',
      '/ws': {
        target: 'ws://localhost:8090',
        ws: true,
        proxyTimeout: 0,
        timeout: 0
      }
    }
  },
  resolve: {
    alias: { '@': '/src' }
  }
})
