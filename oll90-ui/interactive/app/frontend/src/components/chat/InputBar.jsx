import { useState, useRef, useEffect } from 'react'
import useChatStore from '../../stores/chatStore'
import ws from '../../services/websocket'

const SLASH_CMDS = ['/clear', '/new', '/history', '/tools', '/status', '/export', '/help', '/shortcuts', '/sidebar', '/rename']

export default function InputBar({ onSend, onCancel, onClear }) {
  const [input, setInput] = useState('')
  const [history, setHistory] = useState([])
  const [histIdx, setHistIdx] = useState(-1)
  const [slashSuggestions, setSlashSuggestions] = useState([])
  const [slashIdx, setSlashIdx] = useState(0)
  const textareaRef = useRef(null)
  const isStreaming = useChatStore(s => s.isStreaming)

  useEffect(() => {
    if (!isStreaming && textareaRef.current) textareaRef.current.focus()
  }, [isStreaming])

  const handleInputChange = (e) => {
    const val = e.target.value
    setInput(val)
    if (val.startsWith('/') && !val.includes(' ')) {
      const matches = SLASH_CMDS.filter(c => c.startsWith(val.toLowerCase()))
      setSlashSuggestions(matches)
      setSlashIdx(0)
    } else {
      setSlashSuggestions([])
    }
  }

  const executeSlashCmd = (cmd) => {
    setInput('')
    setSlashSuggestions([])
    if (cmd === '/clear') onClear()
    else ws.sendSlashCommand(cmd)
  }

  const handleSubmit = () => {
    const text = input.trim()
    if (!text || isStreaming) return
    if (text.startsWith('/') && SLASH_CMDS.includes(text.toLowerCase())) {
      executeSlashCmd(text.toLowerCase())
      return
    }
    setHistory(h => [text, ...h.slice(0, 49)])
    setHistIdx(-1)
    setInput('')
    setSlashSuggestions([])
    onSend(text)
  }

  const handleKeyDown = (e) => {
    if (slashSuggestions.length > 0) {
      if (e.key === 'Tab' || (e.key === 'Enter' && !e.shiftKey)) {
        e.preventDefault()
        executeSlashCmd(slashSuggestions[slashIdx])
        return
      }
      if (e.key === 'ArrowDown') { e.preventDefault(); setSlashIdx(i => Math.min(i + 1, slashSuggestions.length - 1)); return }
      if (e.key === 'ArrowUp') { e.preventDefault(); setSlashIdx(i => Math.max(i - 1, 0)); return }
      if (e.key === 'Escape') { setSlashSuggestions([]); return }
    }
    if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); handleSubmit() }
    if (e.key === 'ArrowUp' && !input) {
      e.preventDefault()
      if (histIdx < history.length - 1) { const idx = histIdx + 1; setHistIdx(idx); setInput(history[idx]) }
    }
    if (e.key === 'ArrowDown' && histIdx >= 0) {
      e.preventDefault()
      if (histIdx > 0) { const idx = histIdx - 1; setHistIdx(idx); setInput(history[idx]) }
      else { setHistIdx(-1); setInput('') }
    }
  }

  return (
    <div className="border-t border-terminal-border bg-terminal-surface/80 backdrop-blur-sm px-4 py-3 relative">
      {slashSuggestions.length > 0 && (
        <div className="absolute bottom-full left-4 mb-2 bg-terminal-surface border border-terminal-border rounded-lg shadow-2xl shadow-black/40 z-10 min-w-52 overflow-hidden">
          {slashSuggestions.map((cmd, i) => (
            <div
              key={cmd}
              onClick={() => executeSlashCmd(cmd)}
              className={`px-3 py-2 text-[11px] cursor-pointer transition-colors ${i === slashIdx ? 'bg-terminal-cyan/10 text-terminal-cyan border-l-2 border-terminal-cyan' : 'text-terminal-muted hover:bg-terminal-border/30 border-l-2 border-transparent'}`}
            >
              <span className="font-medium">{cmd}</span>
            </div>
          ))}
        </div>
      )}
      <div className="flex items-center gap-3">
        <div className="flex items-center gap-1 shrink-0">
          <span className="text-terminal-cyan/40 text-[10px]">{'>'}</span>
          <span className="text-terminal-cyan font-semibold text-sm">oll90</span>
          <span className="text-terminal-cyan/60 text-sm">$</span>
        </div>
        <textarea
          ref={textareaRef}
          value={input}
          onChange={handleInputChange}
          onKeyDown={handleKeyDown}
          disabled={isStreaming}
          placeholder={isStreaming ? 'Agent is working...' : 'Type a message... (/ for commands)'}
          rows={1}
          className="flex-1 bg-transparent text-terminal-text outline-none resize-none placeholder:text-terminal-muted/40 text-sm disabled:opacity-30 leading-relaxed"
          style={{ minHeight: '22px', maxHeight: '140px' }}
        />
        <div className="flex items-center gap-1.5 shrink-0">
          {isStreaming ? (
            <button
              onClick={onCancel}
              className="px-3 py-1.5 text-[11px] bg-terminal-red/10 text-terminal-red border border-terminal-red/20 rounded-md hover:bg-terminal-red/20 hover:border-terminal-red/40 transition-all font-medium"
            >
              Stop
            </button>
          ) : (
            <>
              <button
                onClick={onClear}
                className="px-2.5 py-1.5 text-[11px] text-terminal-muted/60 hover:text-terminal-yellow hover:bg-terminal-yellow/10 rounded-md transition-all"
                title="Clear (Ctrl+L)"
              >
                CLR
              </button>
              <button
                onClick={handleSubmit}
                disabled={!input.trim()}
                className="px-3.5 py-1.5 text-[11px] bg-terminal-cyan/15 text-terminal-cyan border border-terminal-cyan/20 rounded-md hover:bg-terminal-cyan/25 hover:border-terminal-cyan/40 disabled:opacity-20 disabled:hover:bg-transparent transition-all font-medium glow-cyan"
              >
                Send
              </button>
            </>
          )}
        </div>
      </div>
    </div>
  )
}
