import useChatStore from '../../stores/chatStore'

export default function BottomBar() {
  const { currentStep, maxSteps, elapsed, errorCount, tokensInfo, isStreaming, messages } = useChatStore()

  return (
    <div className="flex items-center justify-between px-4 py-1.5 bg-terminal-surface border-t border-terminal-border text-[11px] relative noise-overlay">
      <div className="flex items-center gap-3 z-10">
        {isStreaming ? (
          <>
            <div className="flex items-center gap-1.5">
              <div className="w-1 h-1 rounded-full bg-terminal-yellow animate-pulse" />
              <span className="text-terminal-yellow font-medium">Step {currentStep}/{maxSteps}</span>
            </div>
            <span className="text-terminal-border">·</span>
            <span className="text-terminal-cyan/80">{elapsed}</span>
            <span className="text-terminal-border">·</span>
            <span className={errorCount > 0 ? 'text-terminal-red' : 'text-terminal-green/60'}>
              {errorCount > 0 ? `${errorCount} err` : 'clean'}
            </span>
          </>
        ) : (
          <div className="flex items-center gap-1.5">
            <div className="w-1 h-1 rounded-full bg-terminal-green/60" />
            <span className="text-terminal-muted/70 uppercase tracking-widest text-[10px]">ready</span>
          </div>
        )}
      </div>
      <div className="flex items-center gap-3 z-10">
        <span className="text-terminal-muted/50">{messages.length} msg</span>
        {tokensInfo && <span className="text-terminal-muted/40">{tokensInfo}</span>}
      </div>
    </div>
  )
}
