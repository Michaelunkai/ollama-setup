import { useState } from 'react'

export default function ThinkingBlock({ content, tokenCount }) {
  const [expanded, setExpanded] = useState(false)
  const preview = content ? content.split('\n')[0].slice(0, 80) : ''

  return (
    <div className="px-4 py-1 fade-in">
      <div
        className="text-[11px] text-terminal-muted/40 cursor-pointer hover:text-terminal-muted/60 transition-colors flex items-center gap-1.5"
        onClick={() => setExpanded(!expanded)}
      >
        <div className="w-1 h-1 rounded-full bg-terminal-muted/30" />
        <span className="text-[10px] uppercase tracking-wider">think</span>
        {!expanded && (
          <span className="italic opacity-50 truncate max-w-md">
            {preview}… {tokenCount && `(${tokenCount}t)`}
          </span>
        )}
        <span className="ml-auto text-[9px]">{expanded ? '−' : '+'}</span>
      </div>
      {expanded && (
        <div className="mt-1.5 text-[11px] text-terminal-muted/40 italic bg-terminal-bg/30 border border-terminal-border/30 rounded-md p-3 max-h-48 overflow-y-auto whitespace-pre-wrap leading-relaxed">
          {content}
        </div>
      )}
    </div>
  )
}
