const API = '/api'

export async function fetchSessions() {
  const res = await fetch(`${API}/sessions`)
  return res.json()
}

export async function createSession(name) {
  const res = await fetch(`${API}/sessions`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ name })
  })
  return res.json()
}

export async function deleteSession(id) {
  await fetch(`${API}/sessions/${id}`, { method: 'DELETE' })
}

export async function getMessages(sessionId) {
  const res = await fetch(`${API}/sessions/${sessionId}/messages`)
  return res.json()
}

export async function getStatus() {
  const res = await fetch(`${API}/status`)
  return res.json()
}

export async function getTools() {
  const res = await fetch(`${API}/tools`)
  return res.json()
}
