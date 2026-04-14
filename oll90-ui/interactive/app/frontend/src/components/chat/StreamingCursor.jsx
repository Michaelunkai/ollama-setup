import useChatStore from '../../stores/chatStore'
import MarkdownRenderer from '../markdown/MarkdownRenderer'

export default function StreamingCursor() {
  const { streamingContent, isStreaming, isThinking, streamingThinking } = useChatStore()

  if (!isStreaming) return null

  return (
    <div className="px-4 py-2">
      {isThinking && streamingThinking && (
        <div className="text-terminal-muted/30 text-[11px] italic mb-2 flex items-center gap-1.5">
          <div className="w-1 h-1 rounded-full bg-terminal-muted/30 animate-pulse" />
          <span className="truncate max-w-lg">{streamingThinking.slice(-200)}</span>
        </div>
      )}
      {streamingContent && (
        <div className="border-l border-terminal-magenta/40 pl-4">
          <div className="text-sm leading-relaxed">
            <MarkdownRenderer content={streamingContent} />
          </div>
        </div>
      )}
      {!streamingContent && !isThinking && (
        <div className="flex items-center gap-2.5 text-terminal-muted/50 text-sm">
          <span className="spinner inline-block w-3 h-3 border border-terminal-cyan/40 border-t-transparent rounded-full" />
          <span className="text-[11px] tracking-wider">processing</span>
        </div>
      )}
      <span className="cursor-blink text-terminal-cyan/60 text-xs ml-0.5">|</span>
    </div>
  )
}
