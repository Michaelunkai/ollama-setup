import { useState, useEffect } from 'react'
import useSessionStore from '../../stores/sessionStore'

const TOOL_GROUPS = {
  'System': ['run_powershell', 'run_cmd', 'run_python', 'get_system_info', 'get_current_datetime', 'env_var', 'screenshot', 'speak', 'notify'],
  'Files': ['write_file', 'read_file', 'edit_file', 'create_directory', 'move_file', 'delete_file', 'list_directory', 'search_files', 'hash_file', 'compress_files', 'extract_archive', 'disk_usage'],
  'Web': ['web_search', 'search_news', 'web_fetch', 'web_fetch_json', 'http_request', 'download_file', 'rss_fetch', 'open_browser', 'web_screenshot', 'url_shorten'],
  'Network': ['dns_lookup', 'port_check', 'network_ping', 'traceroute', 'network_info', 'wifi_info', 'speed_test', 'ssl_cert_info', 'whois_lookup', 'ip_geolocation', 'firewall_status'],
  'Data': ['json_transform', 'base64_tool', 'regex_test', 'clipboard_read', 'clipboard_write'],
  'Windows': ['process_manager', 'service_control', 'event_log', 'scheduled_task', 'registry_query', 'git_command'],
}

export default function Sidebar({ visible }) {
  const { sessions, activeSessionId, createSession, setActiveSession, deleteSession, renameSession } = useSessionStore()
  const [tab, setTab] = useState('sessions')
  const [showNewModal, setShowNewModal] = useState(false)
  const [newName, setNewName] = useState('')
  const [newPrompt, setNewPrompt] = useState('')
  const [editingId, setEditingId] = useState(null)
  const [editName, setEditName] = useState('')

  const handleCreate = async () => {
    await createSession(newName || null, newPrompt || null)
    setNewName('')
    setNewPrompt('')
    setShowNewModal(false)
  }

  if (!visible) return null

  return (
    <div className="w-60 bg-terminal-surface border-r border-terminal-border flex flex-col h-full overflow-hidden relative noise-overlay">
      {/* Tabs */}
      <div className="flex border-b border-terminal-border z-10">
        {['sessions', 'tools'].map(t => (
          <button
            key={t}
            onClick={() => setTab(t)}
            className={`flex-1 py-2.5 text-[11px] uppercase tracking-widest transition-all ${tab === t ? 'text-terminal-cyan border-b-2 border-terminal-cyan bg-terminal-cyan/5' : 'text-terminal-muted/50 hover:text-terminal-text hover:bg-terminal-border/30'}`}
          >
            {t}
          </button>
        ))}
      </div>

      {tab === 'sessions' && (
        <div className="flex-1 overflow-y-auto">
          <button
            onClick={() => setShowNewModal(true)}
            className="w-full py-2 px-3 text-xs text-terminal-green hover:bg-terminal-border text-left"
          >
            + New Session
          </button>
          {showNewModal && (
            <div className="mx-2 my-1 p-2 border border-terminal-border rounded bg-terminal-bg text-xs">
              <input
                className="w-full bg-transparent border-b border-terminal-border outline-none text-terminal-text placeholder:text-terminal-muted mb-1 pb-1"
                placeholder="Session name (optional)"
                value={newName}
                onChange={e => setNewName(e.target.value)}
              />
              <textarea
                className="w-full bg-transparent border border-terminal-border rounded outline-none text-terminal-text placeholder:text-terminal-muted text-[10px] p-1 resize-none"
                placeholder="Custom system prompt (optional)"
                rows={3}
                value={newPrompt}
                onChange={e => setNewPrompt(e.target.value)}
              />
              <div className="flex gap-1 mt-1">
                <button onClick={handleCreate} className="flex-1 py-1 bg-terminal-green/20 text-terminal-green rounded hover:bg-terminal-green/30">Create</button>
                <button onClick={() => setShowNewModal(false)} className="flex-1 py-1 bg-terminal-border text-terminal-muted rounded hover:bg-terminal-border/70">Cancel</button>
              </div>
            </div>
          )}
          {sessions.map(s => (
            <div
              key={s.id}
              onClick={() => setActiveSession(s.id)}
              className={`px-3 py-2 text-xs cursor-pointer hover:bg-terminal-border flex justify-between items-center group ${
                s.id === activeSessionId ? 'border-l-2 border-terminal-cyan bg-terminal-border/50' : ''
              }`}
            >
              <div className="truncate flex-1">
                {editingId === s.id ? (
                  <input
                    className="w-full bg-transparent border-b border-terminal-cyan outline-none text-terminal-text text-xs"
                    value={editName}
                    onChange={e => setEditName(e.target.value)}
                    onKeyDown={e => {
                      if (e.key === 'Enter') { renameSession(s.id, editName); setEditingId(null) }
                      if (e.key === 'Escape') setEditingId(null)
                    }}
                    onBlur={() => { if (editName.trim()) renameSession(s.id, editName); setEditingId(null) }}
                    autoFocus
                    onClick={e => e.stopPropagation()}
                  />
                ) : (
                  <div
                    className="text-terminal-text truncate"
                    onDoubleClick={(e) => { e.stopPropagation(); setEditingId(s.id); setEditName(s.name) }}
                    title="Double-click to rename"
                  >
                    {s.name}
                  </div>
                )}
                <div className="text-terminal-muted text-[10px]">{s.message_count || 0} msgs</div>
              </div>
              <button
                onClick={(e) => { e.stopPropagation(); if (window.confirm(`Delete "${s.name}"?`)) deleteSession(s.id) }}
                className="text-terminal-red opacity-30 hover:opacity-100 ml-2 text-sm leading-none flex-shrink-0"
                title="Delete session"
              >
                ×
              </button>
            </div>
          ))}
        </div>
      )}

      {tab === 'tools' && (
        <div className="flex-1 overflow-y-auto p-3 text-xs text-terminal-muted">
          <div className="mb-2 text-terminal-text">{Object.values(TOOL_GROUPS).flat().length} Tools Available:</div>
          {Object.entries(TOOL_GROUPS).map(([group, tools]) => (
            <div key={group} className="mb-2">
              <div className="text-terminal-cyan text-[10px] uppercase tracking-wider mb-1">{group}</div>
              {tools.map(t => (
                <div key={t} className="py-0.5 text-terminal-yellow pl-2">{t}</div>
              ))}
            </div>
          ))}
        </div>
      )}
    </div>
  )
}
