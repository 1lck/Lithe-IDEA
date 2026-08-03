import { useMemo } from 'react'
import { ToolWindowHeader } from './ToolWindowHeader'
import './StructurePanel.css'

interface Props {
  filePath: string | null
  content: string | null
  language?: string
  onMinimize?: () => void
  onJump?: (line: number) => void
}

interface SymbolRow {
  kind: 'class' | 'interface' | 'enum' | 'method' | 'field' | 'function'
  name: string
  detail?: string
  line: number
  depth: number
}

function parseSymbols(content: string, language?: string): SymbolRow[] {
  const lines = content.split(/\r?\n/)
  const out: SymbolRow[] = []
  const isJava = language === 'java' || language === 'kotlin' || /\.java$|\.kt$/.test(language || '')
  const isTs =
    language === 'typescript' ||
    language === 'javascript' ||
    language === 'tsx' ||
    language === 'jsx'

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]
    const n = i + 1
    let m: RegExpExecArray | null
    if (
      (m = /^\s*(public\s+|private\s+|protected\s+|static\s+|final\s+|abstract\s+)*(class|interface|enum)\s+(\w+)/.exec(
        line
      ))
    ) {
      out.push({
        kind: m[2] === 'interface' ? 'interface' : m[2] === 'enum' ? 'enum' : 'class',
        name: m[3],
        line: n,
        depth: 0
      })
      continue
    }
    if (isJava && (m = /^\s*(public\s+|private\s+|protected\s+|static\s+|final\s+)*[\w.<>,\[\]\s]+\s+(\w+)\s*\(([^;]*)\)\s*(\{|throws|$)/.exec(line))) {
      if (!['if', 'for', 'while', 'switch', 'catch', 'return', 'new'].includes(m[2])) {
        out.push({ kind: 'method', name: m[2], detail: `(${m[3].trim()})`, line: n, depth: 1 })
      }
      continue
    }
    if (isTs && (m = /^\s*(export\s+)?(async\s+)?function\s+(\w+)/.exec(line))) {
      out.push({ kind: 'function', name: m[3], line: n, depth: 0 })
      continue
    }
    if (isTs && (m = /^\s*(export\s+)?(class|interface|enum|type)\s+(\w+)/.exec(line))) {
      out.push({
        kind: m[2] === 'interface' ? 'interface' : m[2] === 'enum' ? 'enum' : 'class',
        name: m[3],
        line: n,
        depth: 0
      })
    }
  }
  return out
}

const KIND_MARK: Record<SymbolRow['kind'], string> = {
  class: 'C',
  interface: 'I',
  enum: 'E',
  method: 'm',
  field: 'f',
  function: 'ƒ'
}

export function StructurePanel({
  filePath,
  content,
  language,
  onMinimize,
  onJump
}: Props): JSX.Element {
  const symbols = useMemo(
    () => (content ? parseSymbols(content, language || filePath || '') : []),
    [content, language, filePath]
  )
  const name = filePath?.split(/[\\/]/).pop() || 'Structure'

  return (
    <div className="structure-panel">
      <ToolWindowHeader title="Structure" subtitle={filePath ? name : undefined} onMinimize={onMinimize}>
        <span className="twh-chip">{symbols.length}</span>
      </ToolWindowHeader>
      <div className="structure-list">
        {!filePath && <div className="structure-empty">Open a file to see structure</div>}
        {filePath && symbols.length === 0 && (
          <div className="structure-empty">No outline symbols detected</div>
        )}
        {symbols.map((s, i) => (
          <button
            key={`${s.line}-${s.name}-${i}`}
            type="button"
            className="structure-row"
            style={{ paddingLeft: 10 + s.depth * 14 }}
            onClick={() => onJump?.(s.line)}
          >
            <span className={`structure-mark k-${s.kind}`}>{KIND_MARK[s.kind]}</span>
            <span className="structure-name">{s.name}</span>
            {s.detail ? <span className="structure-detail">{s.detail}</span> : null}
            <span className="structure-line">{s.line}</span>
          </button>
        ))}
      </div>
    </div>
  )
}
