import { useState } from 'react'
import MarkdownRenderer from '../markdown/MarkdownRenderer'

export default function AgentMessage({ content }) {
  const [copied, setCopied] = useState(false)

  if (!content || !content.trim()) return null

  const clean = content.replace(/<think>[\s\S]*?<\/think>/g, '').trim()
  if (!clean) return null

  const handleCopy = async () => {
    try {
      await navigator.clipboard.writeText(clean)
      setCopied(true)
      setTimeout(() => setCopied(false), 2000)
    } catch (e) {
      const ta = document.createElement('textarea')
      ta.value = clean
      document.body.appendChild(ta)
      ta.select()
      document.execCommand('copy')
      document.body.removeChild(ta)
      setCopied(true)
      setTimeout(() => setCopied(false), 2000)
    }
  }

  return (
    <div className="px-4 py-3 group/msg fade-in">
      <div className="border-l border-terminal-magenta/40 pl-4 relative hover:border-terminal-magenta/70 transition-colors">
        <div className="flex items-center justify-between mb-1.5">
          <div className="flex items-center gap-1.5">
            <div className="w-1 h-1 rounded-full bg-terminal-magenta/60" />
            <span className="text-[10px] text-terminal-magenta/60 uppercase tracking-widest font-medium">oll90</span>
          </div>
          <button
            onClick={handleCopy}
            className="text-[10px] px-2 py-0.5 rounded-md opacity-0 group-hover/msg:opacity-100 transition-all text-terminal-muted/50 hover:text-terminal-cyan hover:bg-terminal-cyan/10 border border-transparent hover:border-terminal-cyan/20"
            title="Copy to clipboard"
          >
            {copied ? 'Copied' : 'Copy'}
          </button>
        </div>
        <div className="text-sm leading-relaxed">
          <MarkdownRenderer content={clean} />
        </div>
      </div>
    </div>
  )
}
