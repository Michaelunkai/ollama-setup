import { useState } from 'react'
import { Prism as SyntaxHighlighter } from 'react-syntax-highlighter'
import { vscDarkPlus } from 'react-syntax-highlighter/dist/esm/styles/prism'

export default function CodeBlock({ language, code }) {
  const [copied, setCopied] = useState(false)

  const handleCopy = () => {
    navigator.clipboard.writeText(code)
    setCopied(true)
    setTimeout(() => setCopied(false), 2000)
  }

  return (
    <div className="relative group mb-2 rounded overflow-hidden border border-terminal-border">
      <div className="flex items-center justify-between px-3 py-1 bg-terminal-surface text-[10px]">
        <span className="text-terminal-muted">{language}</span>
        <button
          onClick={handleCopy}
          className="text-terminal-muted hover:text-terminal-text"
        >
          {copied ? 'Copied!' : 'Copy'}
        </button>
      </div>
      <SyntaxHighlighter
        language={language}
        style={vscDarkPlus}
        customStyle={{
          margin: 0,
          padding: '12px',
          background: '#0d0d0d',
          fontSize: '12px',
          lineHeight: '1.5',
          maxHeight: '400px',
          overflow: 'auto',
        }}
        showLineNumbers
        lineNumberStyle={{ color: '#3a3a3a', fontSize: '10px', minWidth: '2em' }}
      >
        {code}
      </SyntaxHighlighter>
    </div>
  )
}
