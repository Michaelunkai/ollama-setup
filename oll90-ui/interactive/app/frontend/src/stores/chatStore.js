import { create } from 'zustand'

const useChatStore = create((set, get) => ({
  messages: [],
  isStreaming: false,
  streamingContent: '',
  streamingThinking: '',
  isThinking: false,
  currentStep: 0,
  maxSteps: 25,
  elapsed: '00:00',
  errorCount: 0,
  tokensInfo: '',

  addUserMessage: (content) => set((s) => ({
    messages: [...s.messages, {
      id: Date.now(),
      type: 'user',
      content,
      timestamp: new Date().toISOString()
    }]
  })),

  startStreaming: () => set({
    isStreaming: true,
    streamingContent: '',
    streamingThinking: '',
    isThinking: false,
    currentStep: 0,
    errorCount: 0
  }),

  appendContentDelta: (token) => set((s) => ({
    streamingContent: s.streamingContent + token
  })),

  setThinkingActive: (active) => set({ isThinking: active }),

  appendThinkingDelta: (token) => set((s) => ({
    streamingThinking: s.streamingThinking + token
  })),

  finalizeThinking: (tokenCount) => set((s) => ({
    messages: [...s.messages, {
      id: Date.now(),
      type: 'thinking',
      content: s.streamingThinking,
      tokenCount,
      timestamp: new Date().toISOString()
    }],
    streamingThinking: '',
    isThinking: false
  })),

  startToolCall: (callId, name, args) => {
    // First finalize any accumulated streaming content
    const state = get()
    const newMsgs = [...state.messages]
    if (state.streamingContent.trim()) {
      newMsgs.push({
        id: Date.now() - 1,
        type: 'agent_partial',
        content: state.streamingContent,
        timestamp: new Date().toISOString()
      })
    }
    newMsgs.push({
      id: Date.now(),
      type: 'tool_call',
      callId,
      name,
      args,
      status: 'running',
      startTime: Date.now(),
      timestamp: new Date().toISOString()
    })
    set({ messages: newMsgs, streamingContent: '' })
  },

  endToolCall: (callId, result, stderr, success, hint, durationMs, outputChars, blocked) => set((s) => ({
    messages: s.messages.map((m) =>
      m.type === 'tool_call' && m.callId === callId
        ? { ...m, status: blocked ? 'blocked' : success ? 'complete' : 'error', result, stderr, hint, durationMs, outputChars }
        : m
    ),
    errorCount: s.errorCount + (stderr && stderr.trim() ? 1 : 0)
  })),

  finalizeAgentMessage: (doneData) => set((s) => {
    const newMsgs = [...s.messages]
    if (s.streamingContent.trim()) {
      newMsgs.push({
        id: Date.now(),
        type: 'agent',
        content: s.streamingContent,
        timestamp: new Date().toISOString()
      })
    }
    const { type: _ignored, ...restDoneData } = doneData
    newMsgs.push({
      id: Date.now() + 1,
      ...restDoneData,
      type: 'task_complete',
      timestamp: new Date().toISOString()
    })
    return {
      messages: newMsgs,
      streamingContent: '',
      isStreaming: false,
      currentStep: 0
    }
  }),

  updateStatus: (step, maxSteps, elapsed, tokens) => set({
    currentStep: step,
    maxSteps: maxSteps || 25,
    elapsed: elapsed || '00:00',
    tokensInfo: tokens || ''
  }),

  cancelStreaming: () => set((s) => {
    const newMsgs = [...s.messages]
    if (s.streamingContent.trim()) {
      newMsgs.push({
        id: Date.now(),
        type: 'agent',
        content: s.streamingContent,
        timestamp: new Date().toISOString()
      })
    }
    return { messages: newMsgs, streamingContent: '', streamingThinking: '', isStreaming: false }
  }),

  clearMessages: () => set({ messages: [], streamingContent: '', streamingThinking: '' }),

  addInfoMessage: (message) => set((s) => ({
    messages: [...s.messages, {
      id: Date.now(),
      type: 'info',
      content: message,
      timestamp: new Date().toISOString()
    }]
  })),

  addErrorMessage: (message) => set((s) => ({
    messages: [...s.messages, {
      id: Date.now(),
      type: 'error',
      content: message,
      timestamp: new Date().toISOString()
    }]
  })),
}))

export default useChatStore
