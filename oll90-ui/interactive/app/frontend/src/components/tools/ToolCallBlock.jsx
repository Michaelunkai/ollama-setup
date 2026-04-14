import { useState } from 'react'

function truncate(str, max = 100) {
  if (!str) return ''
  return str.length > max ? str.slice(0, max) + '...' : str
}

function formatDuration(ms) {
  if (!ms) return ''
  if (ms < 1000) return `${ms}ms`
  return `${(ms / 1000).toFixed(1)}s`
}

export default function ToolCallBlock({ name, args, status, result, stderr, hint, durationMs, outputChars }) {
  const [expanded, setExpanded] = useState(false)

  const argsPreview = args?.command
    ? truncate(args.command, 80)
    : args?.path
      ? truncate(args.path, 80)
      : args?.query
        ? truncate(args.query, 80)
        : JSON.stringify(args || {}).slice(0, 80)

  const statusConfig = {
    running: { color: 'text-terminal-yellow', bg: 'bg-terminal-yellow/10 border-terminal-yellow/20', label: 'running', dot: 'bg-terminal-yellow animate-pulse' },
    complete: { color: 'text-terminal-green', bg: 'bg-terminal-green/10 border-terminal-green/20', label: 'done', dot: 'bg-terminal-green' },
    error: { color: 'text-terminal-red', bg: 'bg-terminal-red/10 border-terminal-red/20', label: 'error', dot: 'bg-terminal-red' },
    blocked: { color: 'text-terminal-red', bg: 'bg-terminal-red/10 border-terminal-red/20', label: 'blocked', dot: 'bg-terminal-red' },
  }
  const sc = statusConfig[status] || statusConfig.running

  return (
    <div className="px-4 py-1 fade-in">
      <div className="border border-terminal-border/60 rounded-md bg-terminal-bg/40 text-[11px] overflow-hidden">
        <div
          className="flex items-center gap-2 px-3 py-2 cursor-pointer hover:bg-terminal-border/20 transition-colors"
          onClick={() => setExpanded(!expanded)}
        >
          <div className={`w-1.5 h-1.5 rounded-full ${sc.dot} shrink-0`} />
          <span className="text-terminal-yellow font-medium">{name}</span>
          <span className="text-terminal-muted/50 truncate flex-1 font-light">{argsPreview}</span>
          <div className={`px-1.5 py-0.5 rounded text-[9px] uppercase tracking-wider border ${sc.bg} ${sc.color}`}>
            {sc.label}
          </div>
          {durationMs > 0 && (
            <span className="text-terminal-muted/40 text-[10px]">{formatDuration(durationMs)}</span>
          )}
          <span className="text-terminal-muted/30 text-[10px]">{expanded ? '−' : '+'}</span>
        </div>

        {expanded && (
          <div className="border-t border-terminal-border/40 px-3 py-2.5 max-h-80 overflow-y-auto space-y-2 bg-terminal-bg/30">
            <div>
              <div className="text-terminal-muted/50 text-[10px] uppercase tracking-wider mb-1">args</div>
              <pre className="text-terminal-text/80 whitespace-pre-wrap break-all text-[11px] leading-relaxed">
                {JSON.stringify(args, null, 2)}
              </pre>
            </div>
            {result && (
              <div>
                <div className="text-terminal-green/50 text-[10px] uppercase tracking-wider mb-1">output</div>
                <pre className="text-terminal-text/70 whitespace-pre-wrap break-all text-[11px] max-h-48 overflow-y-auto leading-relaxed">
                  {result}
                </pre>
              </div>
            )}
            {stderr && (
              <div>
                <div className="text-terminal-red/50 text-[10px] uppercase tracking-wider mb-1">stderr</div>
                <pre className="text-terminal-red/60 whitespace-pre-wrap break-all text-[11px]">{stderr}</pre>
              </div>
            )}
            {hint && <div className="text-terminal-yellow/60 text-[10px] italic">{hint}</div>}
          </div>
        )}
      </div>
    </div>
  )
}
