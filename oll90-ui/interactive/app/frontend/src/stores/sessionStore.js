import { create } from 'zustand'

const API = '/api'

const useSessionStore = create((set, get) => ({
  sessions: [],
  activeSessionId: null,
  loading: false,

  fetchSessions: async () => {
    try {
      const res = await fetch(`${API}/sessions`)
      const data = await res.json()
      set({ sessions: data })
    } catch (e) {
      console.error('Failed to fetch sessions:', e)
    }
  },

  createSession: async (name, system_prompt) => {
    try {
      const res = await fetch(`${API}/sessions`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name: name || null, system_prompt: system_prompt || null })
      })
      const session = await res.json()
      set((s) => ({
        sessions: [session, ...s.sessions],
        activeSessionId: session.id
      }))
      return session
    } catch (e) {
      console.error('Failed to create session:', e)
      return null
    }
  },

  setActiveSession: (id) => set({ activeSessionId: id }),

  deleteSession: async (id) => {
    try {
      await fetch(`${API}/sessions/${id}`, { method: 'DELETE' })
      set((s) => ({
        sessions: s.sessions.filter((sess) => sess.id !== id),
        activeSessionId: s.activeSessionId === id ? null : s.activeSessionId
      }))
    } catch (e) {
      console.error('Failed to delete session:', e)
    }
  },

  clearSession: async (id) => {
    try {
      await fetch(`${API}/sessions/${id}/clear`, { method: 'POST' })
    } catch (e) {
      console.error('Failed to clear session:', e)
    }
  },

  renameSession: async (id, name) => {
    try {
      await fetch(`${API}/sessions/${id}`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name })
      })
      set((s) => ({
        sessions: s.sessions.map((sess) =>
          sess.id === id ? { ...sess, name } : sess
        )
      }))
    } catch (e) {
      console.error('Failed to rename session:', e)
    }
  },
}))

export default useSessionStore
