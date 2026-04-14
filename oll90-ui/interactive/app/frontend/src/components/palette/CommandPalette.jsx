import { useState, useEffect, useRef } from 'react'

const COMMANDS = [
  { name: '/clear', description: 'Clear conversation history', shortcut: 'Ctrl+L' },
  { name: '/new', description: 'Create new session', shortcut: 'Ctrl+N' },
  { name: '/history', description: 'Show message count and token estimate' },
  { name: '/tools', description: 'List all 53 available tools by category' },
  { name: '/status', description: 'Show model, Ollama, and system status' },
  { name: '/export', description: 'Export session as markdown' },
  { name: '/rename', description: 'Rename current session' },
  { name: '/help', description: 'Show all commands and shortcuts' },
  { name: '/shortcuts', description: 'Show keyboard shortcuts' },
  { name: '/sidebar', description: 'Toggle sidebar', shortcut: 'Ctrl+B' },
]

export default function CommandPalette({ open, onClose, onCommand }) {
  const [filter, setFilter] = useState('')
  const [selected, setSelected] = useState(0)
  const inputRef = useRef(null)

  const filtered = COMMANDS.filter(c =>
    c.name.toLowerCase().includes(filter.toLowerCase()) ||
    c.description.toLowerCase().includes(filter.toLowerCase())
  )

  useEffect(() => {
    if (open) {
      setFilter('')
      setSelected(0)
      setTimeout(() => inputRef.current?.focus(), 50)
    }
  }, [open])

  useEffect(() => {
    const handler = (e) => {
      if (e.key === 'k' && (e.ctrlKey || e.metaKey)) {
        e.preventDefault()
        if (open) onClose()
        else onCommand('__toggle__')
      }
    }
    window.addEventListener('keydown', handler)
    return () => window.removeEventListener('keydown', handler)
  }, [open, onClose, onCommand])

  if (!open) return null

  const handleKeyDown = (e) => {
    if (e.key === 'Escape') onClose()
    if (e.key === 'ArrowDown') { e.preventDefault(); setSelected(s => Math.min(s + 1, filtered.length - 1)) }
    if (e.key === 'ArrowUp') { e.preventDefault(); setSelected(s => Math.max(s - 1, 0)) }
    if (e.key === 'Enter' && filtered[selected]) { onCommand(filtered[selected].name); onClose() }
  }

  return (
    <div className="fixed inset-0 bg-black/70 backdrop-blur-sm flex items-start justify-center pt-20 z-50" onClick={onClose}>
      <div
        className="w-[420px] bg-terminal-surface border border-terminal-border/60 rounded-xl shadow-2xl shadow-black/50 overflow-hidden fade-in"
        onClick={e => e.stopPropagation()}
      >
        <div className="px-4 py-3 border-b border-terminal-border/40 flex items-center gap-2">
          <span className="text-terminal-cyan/40 text-sm">{'>'}</span>
          <input
            ref={inputRef}
            value={filter}
            onChange={e => setFilter(e.target.value)}
            onKeyDown={handleKeyDown}
            placeholder="Type a command..."
            className="flex-1 bg-transparent text-terminal-text outline-none text-sm placeholder:text-terminal-muted/30"
          />
          <kbd className="text-[9px] text-terminal-muted/30 border border-terminal-border/40 rounded px-1.5 py-0.5">ESC</kbd>
        </div>
        <div className="max-h-72 overflow-y-auto py-1">
          {filtered.map((cmd, i) => (
            <div
              key={cmd.name}
              onClick={() => { onCommand(cmd.name); onClose() }}
              className={`mx-1 px-3 py-2 flex justify-between items-center cursor-pointer text-[11px] rounded-md transition-colors ${
                i === selected ? 'bg-terminal-cyan/10 text-terminal-text border-l-2 border-terminal-cyan' : 'text-terminal-muted hover:bg-terminal-border/20 border-l-2 border-transparent'
              }`}
            >
              <div className="flex items-center gap-2">
                <span className={`font-medium ${i === selected ? 'text-terminal-cyan' : 'text-terminal-text/60'}`}>{cmd.name}</span>
                <span className="text-terminal-muted/40">{cmd.description}</span>
              </div>
              {cmd.shortcut && (
                <kbd className="text-[9px] text-terminal-muted/30 border border-terminal-border/30 rounded px-1.5 py-0.5">{cmd.shortcut}</kbd>
              )}
            </div>
          ))}
        </div>
      </div>
    </div>
  )
}
