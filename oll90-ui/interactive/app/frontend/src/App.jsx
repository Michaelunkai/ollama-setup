import { useState, useEffect, useCallback } from 'react'
import './index.css'
import TopBar from './components/layout/TopBar'
import BottomBar from './components/layout/BottomBar'
import Sidebar from './components/layout/Sidebar'
import ChatContainer from './components/chat/ChatContainer'
import InputBar from './components/chat/InputBar'
import CommandPalette from './components/palette/CommandPalette'
import useWebSocket from './hooks/useWebSocket'
import useSessionStore from './stores/sessionStore'
import useStatusStore from './stores/statusStore'
import useChatStore from './stores/chatStore'
import ws from './services/websocket'

function App() {
  const [sidebarOpen, setSidebarOpen] = useState(true)
  const [paletteOpen, setPaletteOpen] = useState(false)
  const { sessions, activeSessionId, fetchSessions, createSession, setActiveSession, clearSession } = useSessionStore()
  const fetchStatus = useStatusStore(s => s.fetchStatus)
  const clearMessages = useChatStore(s => s.clearMessages)
  const { sendMessage, sendCancel } = useWebSocket(activeSessionId)

  // Initial load
  useEffect(() => {
    fetchSessions()
    fetchStatus()
    const interval = setInterval(fetchStatus, 3000)
    return () => clearInterval(interval)
  }, [])

  // Auto-create session if none exists
  useEffect(() => {
    if (sessions.length === 0) return
    if (!activeSessionId) {
      setActiveSession(sessions[0].id)
    }
  }, [sessions, activeSessionId])

  const handleSend = useCallback((text) => {
    if (!activeSessionId) {
      createSession('New Chat').then(session => {
        if (session) {
          setTimeout(() => sendMessage(text), 200)
        }
      })
    } else {
      sendMessage(text)
    }
  }, [activeSessionId, sendMessage, createSession])

  const handleClear = useCallback(() => {
    clearMessages()
    if (activeSessionId) clearSession(activeSessionId)
  }, [clearMessages, clearSession, activeSessionId])

  const handleCommand = useCallback((cmd) => {
    if (cmd === '__toggle__') {
      setPaletteOpen(p => !p)
      return
    }
    setPaletteOpen(false)
    switch (cmd) {
      case '/clear':
        handleClear()
        break
      case '/new':
        createSession()
        break
      case '/sidebar':
        setSidebarOpen(s => !s)
        break
      case '/history':
      case '/tools':
      case '/status':
      case '/help':
      case '/shortcuts':
      case '/rename':
        ws.sendSlashCommand(cmd)
        break
      case '/export':
        ws.sendSlashCommand(cmd)
        break
      default:
        break
    }
  }, [handleClear, createSession])

  // Keyboard shortcuts
  useEffect(() => {
    const handler = (e) => {
      if (e.key === 'l' && (e.ctrlKey || e.metaKey)) {
        e.preventDefault()
        handleClear()
      }
      if (e.key === 'b' && (e.ctrlKey || e.metaKey)) {
        e.preventDefault()
        setSidebarOpen(s => !s)
      }
      if (e.key === 'n' && (e.ctrlKey || e.metaKey)) {
        e.preventDefault()
        createSession()
      }
    }
    window.addEventListener('keydown', handler)
    return () => window.removeEventListener('keydown', handler)
  }, [handleClear, createSession])

  return (
    <div className="h-screen flex flex-col bg-terminal-bg relative">
      <TopBar />
      <div className="flex flex-1 overflow-hidden">
        <Sidebar visible={sidebarOpen} />
        <div className="flex-1 flex flex-col overflow-hidden">
          <ChatContainer />
          <InputBar onSend={handleSend} onCancel={sendCancel} onClear={handleClear} />
        </div>
      </div>
      <BottomBar />
      <CommandPalette
        open={paletteOpen}
        onClose={() => setPaletteOpen(false)}
        onCommand={handleCommand}
      />
    </div>
  )
}

export default App
