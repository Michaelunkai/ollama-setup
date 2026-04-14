import { useEffect, useRef } from 'react'
import ws from '../services/websocket'
import useChatStore from '../stores/chatStore'
import useStatusStore from '../stores/statusStore'

export default function useWebSocket(sessionId) {
  const connected = useRef(false)
  const store = useChatStore
  const status = useStatusStore

  useEffect(() => {
    if (!sessionId) return

    // Disconnect old, clear ALL handlers to prevent duplication
    ws.disconnect()
    ws.clearHandlers()

    ws.on('connected', () => {
      status.getState().setConnected(true)
      connected.current = true
    })

    ws.on('disconnected', () => {
      status.getState().setConnected(false)
      connected.current = false
      // Don't reset streaming state — reconnect will resume
    })

    ws.on('token', (data) => {
      const s = store.getState()
      if (!s.isStreaming) s.startStreaming()
      if (data.thinking) {
        s.appendThinkingDelta(data.content)
      } else {
        s.appendContentDelta(data.content)
      }
    })

    ws.on('thinking_start', () => {
      const s = store.getState()
      if (!s.isStreaming) s.startStreaming()
      s.setThinkingActive(true)
    })

    ws.on('thinking_end', (data) => {
      store.getState().finalizeThinking(data.token_count || 0)
    })

    ws.on('tool_call_start', (data) => {
      store.getState().startToolCall(data.call_id, data.tool, data.args)
    })

    ws.on('tool_call_result', (data) => {
      store.getState().endToolCall(
        data.call_id, data.result, data.stderr,
        data.success, data.hint, data.duration_ms,
        data.output_chars, data.blocked
      )
    })

    ws.on('status', (data) => {
      store.getState().updateStatus(data.step, data.max_steps, data.elapsed, data.tokens)
    })

    ws.on('done', (data) => {
      store.getState().finalizeAgentMessage(data)
      if (data.tokens_per_sec) {
        status.getState().setTokensPerSec(data.tokens_per_sec)
      }
    })

    ws.on('info', (data) => {
      store.getState().addInfoMessage(data.message)
    })

    ws.on('error', (data) => {
      // Only show persistent errors (suppressed duplicates handled in websocket.js)
      if (data.message) {
        store.getState().addInfoMessage(data.message)
      }
    })

    ws.on('loop_detected', () => {
      store.getState().addInfoMessage('Loop detected - forcing new approach')
    })

    ws.on('reprompt', (data) => {
      store.getState().addInfoMessage(`Re-prompt: ${data.reason}`)
    })

    ws.on('cancelled', () => {
      store.getState().cancelStreaming()
      store.getState().addInfoMessage('Generation cancelled by user')
    })

    ws.on('reconnecting', (data) => {
      store.getState().addInfoMessage(`Reconnecting to Ollama (attempt ${data.attempt}/3)...`)
    })

    ws.on('export', (data) => {
      // Download as file
      const blob = new Blob([data.content], { type: 'text/markdown' })
      const url = URL.createObjectURL(blob)
      const a = document.createElement('a')
      a.href = url
      a.download = `oll90-export-${new Date().toISOString().slice(0, 10)}.md`
      a.click()
      URL.revokeObjectURL(url)
      store.getState().addInfoMessage('Session exported as markdown')
    })

    ws.on('reflection', (data) => {
      store.getState().addInfoMessage(`Reflection: ${data.message?.slice(0, 100)}...`)
    })

    ws.connect(sessionId)

    return () => {
      ws.disconnect()
      ws.clearHandlers()
    }
  }, [sessionId])

  return {
    sendMessage: (content) => {
      store.getState().addUserMessage(content)
      store.getState().startStreaming()
      ws.sendMessage(content)
    },
    sendCancel: () => ws.sendCancel(),
    isConnected: connected.current,
  }
}
