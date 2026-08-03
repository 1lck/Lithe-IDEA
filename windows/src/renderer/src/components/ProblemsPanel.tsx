import { useMemo, useState } from 'react'
import { ToolWindowHeader } from './ToolWindowHeader'
import './ProblemsPanel.css'

export type ProblemSeverity = 'error' | 'warning' | 'info'

export interface ProblemItem {
  id: string
  severity: ProblemSeverity
  message: string
  locationTitle: string
  source?: string
  filePath?: string
  line?: number
}

interface Props {
  problems?: ProblemItem[]
  onMinimize?: () => void
  onOpen?: (p: ProblemItem) => void
}

type Filter = 'all' | ProblemSeverity

/** macOS JavaProblemsView chrome — list ready for JDT diagnostics later. */
export function ProblemsPanel({ problems = [], onMinimize, onOpen }: Props): JSX.Element {
  const [filter, setFilter] = useState<Filter>('all')

  const filtered = useMemo(
    () => (filter === 'all' ? problems : problems.filter((p) => p.severity === filter)),
    [problems, filter]
  )

  const counts = useMemo(() => {
    let error = 0
    let warning = 0
    for (const p of problems) {
      if (p.severity === 'error') error++
      if (p.severity === 'warning') warning++
    }
    return { error, warning }
  }, [problems])

  return (
    <div className="problems-panel">
      <ToolWindowHeader title="Problems" subtitle={`${filtered.length}`} onMinimize={onMinimize}>
        <span className="twh-chip err">{counts.error}</span>
        <span className="twh-chip" style={{ color: 'var(--lithe-warning)' }}>
          {counts.warning}
        </span>
        <select
          className="problems-filter"
          value={filter}
          onChange={(e) => setFilter(e.target.value as Filter)}
        >
          <option value="all">All</option>
          <option value="error">Errors</option>
          <option value="warning">Warnings</option>
          <option value="info">Info</option>
        </select>
      </ToolWindowHeader>
      <div className="problems-list">
        {filtered.length === 0 ? (
          <div className="problems-empty">
            <span className="problems-ok">✓</span>
            <div>
              <strong>No problems</strong>
              <p>Java diagnostics will appear here when the language server is connected.</p>
            </div>
          </div>
        ) : (
          filtered.map((p) => (
            <button
              key={p.id}
              type="button"
              className={`problems-row sev-${p.severity}`}
              onClick={() => onOpen?.(p)}
            >
              <span className="problems-sev">{p.severity[0].toUpperCase()}</span>
              <span className="problems-main">
                <span className="problems-loc">
                  {p.locationTitle}
                  {p.source ? ` · ${p.source}` : ''}
                </span>
                <span className="problems-msg">{p.message}</span>
              </span>
            </button>
          ))
        )}
      </div>
    </div>
  )
}
