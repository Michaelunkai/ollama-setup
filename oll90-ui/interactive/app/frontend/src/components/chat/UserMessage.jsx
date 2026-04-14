export default function UserMessage({ content }) {
  return (
    <div className="px-4 py-3 fade-in">
      <div className="flex items-start gap-2.5">
        <div className="flex items-center gap-1 shrink-0 mt-0.5">
          <span className="text-terminal-cyan/40 text-[10px]">{'>'}</span>
          <span className="text-terminal-cyan font-semibold text-xs">you</span>
        </div>
        <pre className="text-terminal-text whitespace-pre-wrap break-words text-sm m-0 leading-relaxed">{content}</pre>
      </div>
    </div>
  )
}
