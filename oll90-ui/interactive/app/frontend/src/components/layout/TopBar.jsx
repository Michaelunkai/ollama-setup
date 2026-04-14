import useStatusStore from '../../stores/statusStore'

export default function TopBar() {
  const { gpuName, gpuUtil, vramUsed, vramTotal, gpuTemp, modelName, tokensPerSec, connected } = useStatusStore()
  const vramGB = (vramUsed / 1024).toFixed(1)
  const vramTotalGB = (vramTotal / 1024).toFixed(1)
  const vramPct = vramTotal > 0 ? (vramUsed / vramTotal * 100) : 0
  const vramColor = vramPct > 95 ? 'text-terminal-red' : vramPct > 80 ? 'text-terminal-yellow' : 'text-terminal-green'

  return (
    <div className="flex items-center justify-between px-4 py-2 bg-terminal-surface border-b border-terminal-border text-[11px] relative noise-overlay">
      <div className="flex items-center gap-3 z-10">
        <div className="flex items-center gap-1.5">
          <div className="w-1.5 h-4 bg-terminal-cyan rounded-sm" />
          <span className="text-terminal-cyan font-bold tracking-wider text-xs">OLL90</span>
        </div>
        <span className="text-terminal-muted/60">|</span>
        <span className="text-terminal-muted font-light">{modelName}</span>
        <div className="flex items-center gap-2 ml-2 px-2 py-0.5 rounded bg-terminal-bg/50 border border-terminal-border/50">
          <span className="text-terminal-blue">GPU {gpuUtil}%</span>
          <span className="text-terminal-border">·</span>
          <span className={vramColor}>{vramGB}/{vramTotalGB}G</span>
          {gpuTemp > 0 && (
            <>
              <span className="text-terminal-border">·</span>
              <span className="text-terminal-orange">{gpuTemp}°</span>
            </>
          )}
        </div>
        {tokensPerSec > 0 && (
          <div className="px-2 py-0.5 rounded bg-terminal-green/10 border border-terminal-green/20">
            <span className="text-terminal-green font-medium">{tokensPerSec} tok/s</span>
          </div>
        )}
      </div>
      <div className="flex items-center gap-2 z-10">
        <div className={`w-1.5 h-1.5 rounded-full ${connected ? 'bg-terminal-green shadow-[0_0_6px_rgba(63,185,80,0.5)]' : 'bg-terminal-red shadow-[0_0_6px_rgba(248,81,73,0.5)]'}`} />
        <span className={`text-[10px] uppercase tracking-wider ${connected ? 'text-terminal-green/70' : 'text-terminal-red/70'}`}>
          {connected ? 'live' : 'offline'}
        </span>
      </div>
    </div>
  )
}
