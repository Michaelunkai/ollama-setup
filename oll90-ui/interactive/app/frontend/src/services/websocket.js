class WS {
  constructor() {
    this.ws = null
    this.sessionId = null
    this.handlers = {}
    this.reconnectTimer = null
    this.reconnectDelay = 1000
    this.lastPingTime = 0
    this.pingWatchdog = null
    this._wasStreaming = false
    this._reconnectAttempts = 0
    this._maxSilentReconnects = 10
    this._lastErrorTime = 0
    this._errorCooldownMs = 5000
  }

  on(event, handler) {
    if (!this.handlers[event]) this.handlers[event] = []
    this.handlers[event].push(handler)
  }

  off(event) {
    delete this.handlers[event]
  }

  clearHandlers() {
    this.handlers = {}
  }

  emit(event, data) {
    (this.handlers[event] || []).forEach(h => h(data))
  }

  connect(sessionId) {
    this.sessionId = sessionId

    // Clean up any existing connection first
    if (this.ws) {
      try { this.ws.close() } catch (e) { /* ignore */ }
      this.ws = null
    }

    const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:'
    const url = `${protocol}//${window.location.host}/ws/${sessionId}`

    try {
      this.ws = new WebSocket(url)
    } catch (e) {
      this.emit('error', { message: 'Failed to connect' })
      this.scheduleReconnect()
      return
    }

    this.ws.onopen = () => {
      this.reconnectDelay = 1000
      this._reconnectAttempts = 0
      this.lastPingTime = Date.now()
      this.startPingWatchdog()
      this.emit('connected', { sessionId })
    }

    this.ws.onmessage = (evt) => {
      try {
        const data = JSON.parse(evt.data)

        if (data.type === 'ping') {
          this.lastPingTime = Date.now()
          this.send({ type: 'pong' })
          return
        }

        this.emit(data.type, data)
        this.emit('message', data)
      } catch (e) {
        // parse error on non-JSON message, ignore
      }
    }

    this.ws.onclose = (evt) => {
      this.stopPingWatchdog()
      // Only emit disconnected if reconnect limit exceeded
      if (this._reconnectAttempts >= this._maxSilentReconnects) {
        this.emit('disconnected', { code: evt.code, wasClean: evt.wasClean })
      }
      // Only reconnect if we still have a session (not intentional disconnect)
      if (this.sessionId) {
        this.scheduleReconnect()
      }
    }

    this.ws.onerror = () => {
      // Suppress error spam: only emit after cooldown AND exceeded silent reconnect limit
      const now = Date.now()
      if (this._reconnectAttempts >= this._maxSilentReconnects &&
          now - this._lastErrorTime > this._errorCooldownMs) {
        this._lastErrorTime = now
        this.emit('error', { message: `WebSocket reconnecting (attempt ${this._reconnectAttempts})` })
      }
    }
  }

  startPingWatchdog() {
    this.stopPingWatchdog()
    // Check every 30s if we got a ping in last 300s
    // (tolerates tool runs up to 180s + Ollama generation up to 600s)
    this.pingWatchdog = setInterval(() => {
      if (Date.now() - this.lastPingTime > 300000) {
        // No ping from server in 300s — connection is truly stale
        this.stopPingWatchdog()
        if (this.ws) {
          try { this.ws.close() } catch (e) { /* triggers onclose -> reconnect */ }
        }
      }
    }, 30000)
  }

  stopPingWatchdog() {
    if (this.pingWatchdog) {
      clearInterval(this.pingWatchdog)
      this.pingWatchdog = null
    }
  }

  scheduleReconnect() {
    if (this.reconnectTimer) return
    this._reconnectAttempts++
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null
      if (this.sessionId) {
        this.connect(this.sessionId)
      }
    }, Math.min(this.reconnectDelay, 10000))
    this.reconnectDelay = Math.min(this.reconnectDelay * 1.5, 10000)
  }

  send(data) {
    if (this.ws && this.ws.readyState === WebSocket.OPEN) {
      try {
        this.ws.send(JSON.stringify(data))
      } catch (e) {
        // send failed — connection dying, will trigger onclose
      }
    }
  }

  sendMessage(content) {
    this.send({ type: 'message', content })
  }

  sendCancel() {
    this.send({ type: 'cancel' })
  }

  sendSlashCommand(command) {
    this.send({ type: 'slash_command', command })
  }

  disconnect() {
    this.sessionId = null  // Set first to prevent reconnect in onclose
    this.stopPingWatchdog()
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer)
      this.reconnectTimer = null
    }
    if (this.ws) {
      try { this.ws.close() } catch (e) { /* ignore */ }
      this.ws = null
    }
  }
}

export const ws = new WS()
export default ws
