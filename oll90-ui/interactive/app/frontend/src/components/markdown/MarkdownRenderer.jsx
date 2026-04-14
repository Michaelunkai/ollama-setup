import ReactMarkdown from 'react-markdown'
import remarkGfm from 'remark-gfm'
import CodeBlock from './CodeBlock'

export default function MarkdownRenderer({ content }) {
  return (
    <ReactMarkdown
      remarkPlugins={[remarkGfm]}
      components={{
        code({ inline, className, children, ...props }) {
          const match = /language-(\w+)/.exec(className || '')
          if (!inline && match) {
            return <CodeBlock language={match[1]} code={String(children).replace(/\n$/, '')} />
          }
          if (!inline && !match && String(children).includes('\n')) {
            return <CodeBlock language="text" code={String(children).replace(/\n$/, '')} />
          }
          return (
            <code className="bg-terminal-surface px-1.5 py-0.5 rounded text-terminal-cyan text-[12px]" {...props}>
              {children}
            </code>
          )
        },
        p({ children }) {
          return <p className="mb-2 leading-relaxed">{children}</p>
        },
        h1({ children }) { return <h1 className="text-lg font-bold text-terminal-text mb-2 mt-3">{children}</h1> },
        h2({ children }) { return <h2 className="text-base font-bold text-terminal-text mb-2 mt-3">{children}</h2> },
        h3({ children }) { return <h3 className="text-sm font-bold text-terminal-text mb-1 mt-2">{children}</h3> },
        ul({ children }) { return <ul className="list-disc ml-4 mb-2">{children}</ul> },
        ol({ children }) { return <ol className="list-decimal ml-4 mb-2">{children}</ol> },
        li({ children }) { return <li className="mb-0.5">{children}</li> },
        strong({ children }) { return <strong className="text-terminal-text font-bold">{children}</strong> },
        em({ children }) { return <em className="text-terminal-text/80">{children}</em> },
        table({ children }) {
          return (
            <div className="overflow-x-auto mb-2">
              <table className="border-collapse border border-terminal-border text-xs w-full">
                {children}
              </table>
            </div>
          )
        },
        th({ children }) {
          return <th className="border border-terminal-border px-2 py-1 bg-terminal-surface text-terminal-cyan text-left">{children}</th>
        },
        td({ children }) {
          return <td className="border border-terminal-border px-2 py-1">{children}</td>
        },
        blockquote({ children }) {
          return <blockquote className="border-l-2 border-terminal-muted pl-3 italic text-terminal-muted mb-2">{children}</blockquote>
        },
        hr() { return <hr className="border-terminal-border my-3" /> },
        a({ href, children }) {
          return <a href={href} className="text-terminal-cyan underline" target="_blank" rel="noopener noreferrer">{children}</a>
        },
      }}
    >
      {content}
    </ReactMarkdown>
  )
}
