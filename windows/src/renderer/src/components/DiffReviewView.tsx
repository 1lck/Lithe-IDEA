import { useEffect, useMemo, useState } from 'react'
import './DiffReviewView.css'

export interface DiffTarget {
  path: string
  staged: boolean
}

interface Props {
  projectPath: string
  target: DiffTarget
  onClose: () => void
  onChanged?: () => void
}

interface DiffLine {
  type: 'ctx' | 'add' | 'del' | 'hunk' | 'meta'
  text: string
  oldNo?: number
  newNo?: number
}

function parseUnifiedDiff(raw: string): DiffLine[] {
  const out: DiffLine[] = []
  let oldNo = 0
  let newNo = 0
  for (const line of raw.split(/\r?\n/)) {
    if (line.startsWith('@@')) {
      const m = line.match(/@@\s+-(\d+)(?:,\d+)?\s+\+(\d+)/)
      if (m) {
        oldNo = Number(m[1])
        newNo = Number(m[2])
      }
      out.push({ type: 'hunk', text: line })
      continue
    }
    if (line.startsWith('diff ') || line.startsWith('index ') || line.startsWith('---') || line.startsWith('+++')) {
      out.push({ type: 'meta', text: line })
      continue
    }
    if (line.startsWith('+')) {
      out.push({ type: 'add', text: line.slice(1), newNo })
      newNo++
      continue
    }
    if (line.startsWith('-')) {
      out.push({ type: 'del', text: line.slice(1), oldNo })
      oldNo++
      continue
    }
    if (line.startsWith('\\')) {
      out.push({ type: 'meta', text: line })
      continue
    }
    out.push({ type: 'ctx', text: line.startsWith(' ') ? line.slice(1) : line, oldNo, newNo })
    oldNo++
    newNo++
  }
  return out
}

function fileName(p: string): string {
  const parts = p.split(/[\\/]/)
  return parts[parts.length - 1] || p
}

/** macOS DiffReviewView — unified diff review over editor area. */
export function DiffReviewView({ projectPath, target, onClose, onChanged }: Props): JSX.Element {
  const [raw, setRaw] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [query, setQuery] = useState('')
  const [layout, setLayout] = useState<'unified' | 'split'>('unified')

  const load = async (): Promise<void> => {
    setBusy(true)
    setError(null)
    try {
      const diff = await window.api.gitDiff(projectPath, target.path, target.staged)
      setRaw(diff || '')
    } catch (e: any) {
      setError(e?.message || String(e))
      setRaw('')
    } finally {
      setBusy(false)
    }
  }

  useEffect(() => {
    void load()
  }, [projectPath, target.path, target.staged])

  const lines = useMemo(() => parseUnifiedDiff(raw), [raw])
  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase()
    if (!q) return lines
    return lines.filter((l) => l.text.toLowerCase().includes(q) || l.type === 'hunk' || l.type === 'meta')
  }, [lines, query])

  const stats = useMemo(() => {
    let add = 0
    let del = 0
    for (const l of lines) {
      if (l.type === 'add') add++
      if (l.type === 'del') del++
    }
    return { add, del, changes: add + del }
  }, [lines])

  const stageToggle = async (): Promise<void> => {
    setBusy(true)
    try {
      if (target.staged) await window.api.gitUnstage(projectPath, [target.path])
      else await window.api.gitStage(projectPath, [target.path])
      onChanged?.()
      onClose()
    } catch (e: any) {
      setError(e?.message || String(e))
    } finally {
      setBusy(false)
    }
  }

  const discard = async (): Promise<void> => {
    if (target.staged) return
    if (!window.confirm(`Discard changes in “${target.path}”?`)) return
    setBusy(true)
    try {
      await window.api.gitDiscard(projectPath, [target.path])
      onChanged?.()
      onClose()
    } catch (e: any) {
      setError(e?.message || String(e))
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="diff-review">
      <div className="diff-filetab">
        <div className="diff-filetab-main">
          <svg viewBox="0 0 16 16" width="14" height="14" aria-hidden>
            <path d="M4 2h6l3 3v9H4V2z" fill="none" stroke="currentColor" strokeWidth="1.3" />
            <path d="M10 2v3h3" fill="none" stroke="currentColor" strokeWidth="1.3" />
          </svg>
          <strong>{fileName(target.path)}</strong>
          <em className="diff-badge kind">DIFF</em>
          <em className={`diff-badge ${target.staged ? 'staged' : 'work'}`}>
            {target.staged ? 'STAGED' : 'WORKING TREE'}
          </em>
        </div>
        <button type="button" className="diff-close" onClick={onClose} aria-label="Close diff">
          ×
        </button>
      </div>

      <div className="diff-toolbar">
        <input
          className="diff-search"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          placeholder="Search in diff…"
        />
        <div className="diff-toolbar-group">
          <button
            type="button"
            className={layout === 'unified' ? 'active' : ''}
            onClick={() => setLayout('unified')}
          >
            Unified
          </button>
          <button
            type="button"
            className={layout === 'split' ? 'active' : ''}
            onClick={() => setLayout('split')}
          >
            Side-by-side
          </button>
        </div>
        <span className="diff-meta">
          {target.path} · {stats.changes} differences
          <i className="add">+{stats.add}</i>
          <i className="del">−{stats.del}</i>
        </span>
        <div className="diff-toolbar-spacer" />
        {!target.staged && (
          <button type="button" className="diff-action danger" disabled={busy} onClick={() => void discard()}>
            Discard
          </button>
        )}
        <button type="button" className="diff-action primary" disabled={busy} onClick={() => void stageToggle()}>
          {target.staged ? 'Unstage File' : 'Stage File'}
        </button>
      </div>

      {error && <div className="diff-error">{error}</div>}

      <div className={`diff-body layout-${layout}`}>
        {busy && !raw ? (
          <div className="diff-empty">Loading diff…</div>
        ) : !raw ? (
          <div className="diff-empty">No differences</div>
        ) : layout === 'unified' ? (
          <div className="diff-unified">
            {filtered.map((l, i) => (
              <div key={i} className={`diff-row t-${l.type}`}>
                <span className="diff-gutter">
                  {l.type === 'add' || l.type === 'ctx' ? l.newNo ?? '' : ''}
                </span>
                <span className="diff-gutter old">
                  {l.type === 'del' || l.type === 'ctx' ? l.oldNo ?? '' : ''}
                </span>
                <span className="diff-sign">
                  {l.type === 'add' ? '+' : l.type === 'del' ? '−' : l.type === 'hunk' ? '@' : ' '}
                </span>
                <code>{l.text || '\u00a0'}</code>
              </div>
            ))}
          </div>
        ) : (
          <div className="diff-split">
            <div className="diff-pane">
              <div className="diff-pane-head">Before</div>
              {filtered
                .filter((l) => l.type !== 'add')
                .map((l, i) => (
                  <div key={i} className={`diff-row t-${l.type === 'del' ? 'del' : l.type}`}>
                    <span className="diff-gutter">{l.oldNo ?? ''}</span>
                    <code>{l.type === 'hunk' || l.type === 'meta' ? l.text : l.text || '\u00a0'}</code>
                  </div>
                ))}
            </div>
            <div className="diff-pane">
              <div className="diff-pane-head">After</div>
              {filtered
                .filter((l) => l.type !== 'del')
                .map((l, i) => (
                  <div key={i} className={`diff-row t-${l.type === 'add' ? 'add' : l.type}`}>
                    <span className="diff-gutter">{l.newNo ?? ''}</span>
                    <code>{l.type === 'hunk' || l.type === 'meta' ? l.text : l.text || '\u00a0'}</code>
                  </div>
                ))}
            </div>
          </div>
        )}
      </div>
    </div>
  )
}
