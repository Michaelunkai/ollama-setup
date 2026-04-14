import { useEffect, useRef } from 'react'
import useChatStore from '../../stores/chatStore'
import UserMessage from './UserMessage'
import AgentMessage from './AgentMessage'
import StreamingCursor from './StreamingCursor'
import ToolCallBlock from '../tools/ToolCallBlock'
import ThinkingBlock from '../thinking/ThinkingBlock'

export default function ChatContainer() {
  const { messages, isStreaming } = useChatStore()
  const bottomRef = useRef(null)

  useEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: 'smooth' })
  }, [messages, isStreaming])

  return (
    <div className="flex-1 overflow-y-auto">
      {messages.length === 0 && !isStreaming && (
        <div className="flex items-center justify-center h-full text-terminal-muted">
          <div className="text-center">
            <div className="text-2xl mb-2 text-terminal-magenta">OLL90</div>
            <div className="text-xs">Autonomous AI Agent</div>
            <div className="text-xs mt-1">qwen3-14b-oll90 | RTX 5080 16GB | 23 tools</div>
            <div className="text-xs mt-4 text-terminal-cyan">Type a message to begin</div>
          </div>
        </div>
      )}

      {messages.map((msg) => {
        switch (msg.type) {
          case 'user':
            return <UserMessage key={msg.id} content={msg.content} />
          case 'agent':
          case 'agent_partial':
            return <AgentMessage key={msg.id} content={msg.content} />
          case 'tool_call':
            return <ToolCallBlock key={msg.id} {...msg} />
          case 'thinking':
            return <ThinkingBlock key={msg.id} content={msg.content} tokenCount={msg.tokenCount} />
          case 'task_complete':
            return (
              <div key={msg.id} className="px-4 py-2">
                <div className="text-xs border border-terminal-border rounded px-3 py-2 bg-terminal-surface">
                  <span className={msg.had_errors ? 'text-terminal-yellow' : 'text-terminal-green'}>
                    {msg.had_errors ? 'COMPLETED WITH ERRORS' : 'COMPLETED'}
                  </span>
                  <span className="text-terminal-muted mx-2">|</span>
                  <span className="text-terminal-text">Steps: {msg.total_steps}</span>
                  <span className="text-terminal-muted mx-2">|</span>
                  <span className="text-terminal-text">Tools: {msg.total_tool_calls}</span>
                  <span className="text-terminal-muted mx-2">|</span>
                  <span className="text-terminal-text">Time: {msg.duration}</span>
                  {msg.tokens_per_sec > 0 && (
                    <>
                      <span className="text-terminal-muted mx-2">|</span>
                      <span className="text-terminal-cyan">{msg.tokens_per_sec} tok/s</span>
                    </>
                  )}
                </div>
              </div>
            )
          case 'info':
            return (
              <div key={msg.id} className="px-4 py-1 text-xs text-terminal-cyan">
                [INFO] {msg.content}
              </div>
            )
          case 'error':
            return (
              <div key={msg.id} className="px-4 py-1 text-xs text-terminal-red">
                [ERROR] {msg.content}
              </div>
            )
          case 'reconnecting':
            return (
              <div key={msg.id} className="px-4 py-1 text-xs text-terminal-yellow">
                [RECONNECTING] {msg.content}
              </div>
            )
          default:
            return null
        }
      })}

      {isStreaming && <StreamingCursor />}

      <div ref={bottomRef} className="h-4" />
    </div>
  )
}
