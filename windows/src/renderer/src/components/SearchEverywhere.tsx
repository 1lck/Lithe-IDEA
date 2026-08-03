import { useState, useEffect, useCallback, useMemo, useRef } from 'react'
import { IPC } from '../../../common/ipc'
import type { SearchResult } from '../../../common/types'
import './SearchEverywhere.css'

type Scope = 'all' | 'type' | 'file' | 'symbol' | 'content' | 'actions'

const SCOPES: { id: Scope; label: string }[] = [
  { id: 'all', label: 'All' },
  { id: 'type', label: 'Classes' },
  { id: 'file', label: 'Files' },
  { id: 'symbol', label: 'Symbols' },
  { id: 'content', label: 'Text' },
  { id: 'actions', label: 'Actions' }
]

const KIND_LABEL: Record<SearchResult['kind'], string> = {
  file: 'Files',
  type: 'Classes',
  symbol: 'Symbols',
  content: 'Text'
}

const ACTIONS = [
  { id: 'settings', label: 'Open Settings', hint: 'Ctrl+,', preview: 'Preferences' },
  { id: 'plugins', label: 'Plugins', hint: '', preview: 'Preferences' },
  { id: 'terminal', label: 'Toggle Terminal', hint: 'Alt+F12', preview: 'Tool Windows' },
  { id: 'search-files', label: 'Find in Files', hint: 'Ctrl+Shift+F', preview: 'Search' },
  { id: 'close-project', label: 'Close Project', hint: '', preview: 'File' }
]

interface Props {
  projectPath: string
  onClose: () => void
  onOpenFile: (path: string, line?: number) => void
  onAction?: (actionId: string) => void
  extraActions?: Array<{ id: string; label: string; hint?: string; preview: string }>
}

async function searchProject(root: string, query: string): Promise<SearchResult[]> {
  return (window as any).electron.ipcRenderer.invoke(IPC.SEARCH_PROJECT, root, { query })
}

function fileName(path: string): string {
  return path.split(/[\\/]/).pop() || path
}

function parentPath(path: string): string {
  const parts = path.split(/[\\/]/)
  parts.pop()
  return parts.slice(-3).join('/') || path
}

function extTone(name: string): string {
  const ext = name.split('.').pop()?.toLowerCase() || ''
  if (['java', 'kt', 'kts'].includes(ext)) return 'java'
  if (['ts', 'tsx', 'js', 'jsx'].includes(ext)) return 'web'
  if (['swift'].includes(ext)) return 'swift'
  if (['xml', 'json', 'yml', 'yaml', 'properties'].includes(ext)) return 'data'
  if (['md', 'txt'].includes(ext)) return 'doc'
  return 'default'
}

function highlightMatch(text: string, query: string): JSX.Element {
  if (!query.trim()) return <>{text}</>
  const q = query.trim()
  const lower = text.toLowerCase()
  const idx = lower.indexOf(q.toLowerCase())
  if (idx < 0) return <>{text}</>
  return (
    <>
      {text.slice(0, idx)}
      <mark className="se-mark">{text.slice(idx, idx + q.length)}</mark>
      {text.slice(idx + q.length)}
    </>
  )
}

export function SearchEverywhere({
  projectPath,
  onClose,
  onOpenFile,
  onAction,
  extraActions = []
}: Props): JSX.Element {
  const [query, setQuery] = useState('')
  const [scope, setScope] = useState<Scope>('all')
  const [results, setResults] = useState<SearchResult[]>([])
  const [selected, setSelected] = useState(0)
  const [loading, setLoading] = useState(false)
  const inputRef = useRef<HTMLInputElement>(null)
  const listRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    const handler = (e: KeyboardEvent): void => {
      if (e.key === 'Escape') onClose()
    }
    window.addEventListener('keydown', handler)
    return () => window.removeEventListener('keydown', handler)
  }, [onClose])

  useEffect(() => {
    if (!query.trim()) {
      setResults([])
      setLoading(false)
      return
    }
    let cancelled = false
    setLoading(true)
    const t = setTimeout(async () => {
      try {
        const r = await searchProject(projectPath, query)
        if (!cancelled) {
          setResults(r.slice(0, 200))
          setSelected(0)
        }
      } catch {
        if (!cancelled) setResults([])
      } finally {
        if (!cancelled) setLoading(false)
      }
    }, 160)
    return () => {
      cancelled = true
      clearTimeout(t)
    }
  }, [query, projectPath])

  const allActions = useMemo(() => [...ACTIONS, ...extraActions], [extraActions])

  const actionHits = useMemo(() => {
    if (scope !== 'all' && scope !== 'actions') return []
    const q = query.trim().toLowerCase()
    if (!q) return []
    return allActions.filter(
      (a) => a.label.toLowerCase().includes(q) || a.preview.toLowerCase().includes(q)
    )
  }, [query, scope, allActions])

  const filtered = useMemo(() => {
    if (scope === 'actions') return []
    if (scope === 'all') return results
    return results.filter((r) => r.kind === scope)
  }, [results, scope])

  const groups = useMemo(() => {
    const order: SearchResult['kind'][] = ['file', 'type', 'symbol', 'content']
    return order
      .map((kind) => ({ kind, items: filtered.filter((r) => r.kind === kind) }))
      .filter((g) => g.items.length > 0)
  }, [filtered])

  type FlatItem =
    | { type: 'result'; result: SearchResult; flatIndex: number }
    | { type: 'action'; action: (typeof allActions)[number]; flatIndex: number }

  const flatItems = useMemo(() => {
    const items: FlatItem[] = []
    let i = 0
    for (const g of groups) {
      for (const r of g.items) {
        items.push({ type: 'result', result: r, flatIndex: i++ })
      }
    }
    for (const a of actionHits) {
      items.push({ type: 'action', action: a, flatIndex: i++ })
    }
    return items
  }, [groups, actionHits])

  const activate = useCallback((idx: number) => {
    const item = flatItems[idx]
    if (!item) return
    if (item.type === 'result') {
      onOpenFile(item.result.path, item.result.line)
      onClose()
    } else {
      onAction?.(item.action.id)
      onClose()
    }
  }, [flatItems, onClose, onOpenFile, onAction])

  useEffect(() => {
    const el = listRef.current?.querySelector(`[data-idx="${selected}"]`)
    el?.scrollIntoView({ block: 'nearest' })
  }, [selected])

  const totalCount = flatItems.length
  const showIdle = !query.trim()
  const showEmpty = !showIdle && !loading && totalCount === 0

  return (
    <div className="se-overlay" onClick={onClose} role="presentation">
      <div
        className="se-modal"
        onClick={(e) => e.stopPropagation()}
        role="dialog"
        aria-label="Search Everywhere"
      >
        <div className="se-tabs" role="tablist">
          {SCOPES.map((s) => (
            <button
              key={s.id}
              type="button"
              role="tab"
              aria-selected={scope === s.id}
              className={`se-tab ${scope === s.id ? 'active' : ''}`}
              onClick={() => { setScope(s.id); setSelected(0); inputRef.current?.focus() }}
            >
              {s.label}
            </button>
          ))}
        </div>

        <div className="se-field">
          <svg className="se-field-icon" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
            <circle cx="6.5" cy="6.5" r="4.5" /><path d="M10 10l4 4" />
          </svg>
          <input
            ref={inputRef}
            className="se-input"
            autoFocus
            placeholder={scope === 'all' ? 'Search Everywhere' : `Search ${SCOPES.find((s) => s.id === scope)?.label}`}
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === 'ArrowDown') {
                e.preventDefault()
                setSelected((s) => Math.min(s + 1, Math.max(totalCount - 1, 0)))
              }
              if (e.key === 'ArrowUp') {
                e.preventDefault()
                setSelected((s) => Math.max(s - 1, 0))
              }
              if (e.key === 'Enter') activate(selected)
              if (e.key === 'Tab' && !e.shiftKey) {
                e.preventDefault()
                const idx = SCOPES.findIndex((s) => s.id === scope)
                setScope(SCOPES[(idx + 1) % SCOPES.length].id)
              }
            }}
          />
          {query && (
            <button
              type="button"
              className="se-clear"
              title="Clear"
              onClick={() => { setQuery(''); inputRef.current?.focus() }}
            >
              &times;
            </button>
          )}
          {loading && <span className="se-spinner" aria-label="Searching" />}
        </div>

        <div className="se-body" ref={listRef}>
          {showIdle && (
            <div className="se-idle">
              <p className="se-idle-title">Search across the project</p>
              <ul className="se-idle-hints">
                <li><kbd>↑</kbd><kbd>↓</kbd> navigate</li>
                <li><kbd>Enter</kbd> open</li>
                <li><kbd>Tab</kbd> switch scope</li>
                <li><kbd>Esc</kbd> dismiss</li>
              </ul>
            </div>
          )}

          {showEmpty && (
            <div className="se-empty">
              <p>No results for <strong>{query}</strong></p>
              <span>Try another scope or a shorter query</span>
            </div>
          )}

          {!showIdle && groups.map((g) => (
            <section key={g.kind} className="se-group">
              <header className="se-group-title">{KIND_LABEL[g.kind]}</header>
              {g.items.map((r) => {
                const idx = flatItems.find((f) => f.type === 'result' && f.result === r)?.flatIndex ?? 0
                const name = r.symbolName || fileName(r.path)
                const isSelected = idx === selected
                return (
                  <button
                    key={`${r.kind}-${r.path}-${r.line}-${idx}`}
                    type="button"
                    data-idx={idx}
                    className={`se-row ${isSelected ? 'selected' : ''}`}
                    onMouseEnter={() => setSelected(idx)}
                    onClick={() => activate(idx)}
                  >
                    <span className={`se-file-icon tone-${extTone(fileName(r.path))}`} aria-hidden="true">
                      {fileName(r.path).split('.').pop()?.slice(0, 2).toUpperCase() || '·'}
                    </span>
                    <span className="se-row-main">
                      <span className="se-row-name">
                        {highlightMatch(name, query)}
                        {r.kind === 'content' && r.line != null && (
                          <span className="se-row-line">:{r.line}</span>
                        )}
                      </span>
                      {r.kind === 'content' && r.preview && (
                        <span className="se-row-preview">{highlightMatch(r.preview.trim(), query)}</span>
                      )}
                    </span>
                    <span className="se-row-path" title={r.path}>
                      {r.kind === 'content' ? fileName(r.path) : parentPath(r.path)}
                    </span>
                  </button>
                )
              })}
            </section>
          ))}

          {actionHits.length > 0 && (
            <section className="se-group">
              <header className="se-group-title">Actions</header>
              {actionHits.map((a) => {
                const idx = flatItems.find((f) => f.type === 'action' && f.action.id === a.id)?.flatIndex ?? 0
                return (
                  <button
                    key={a.id}
                    type="button"
                    data-idx={idx}
                    className={`se-row ${idx === selected ? 'selected' : ''}`}
                    onMouseEnter={() => setSelected(idx)}
                    onClick={() => activate(idx)}
                  >
                    <span className="se-file-icon tone-action" aria-hidden="true">A</span>
                    <span className="se-row-main">
                      <span className="se-row-name">{highlightMatch(a.label, query)}</span>
                      <span className="se-row-preview">{a.preview}</span>
                    </span>
                    {a.hint && <span className="se-row-hint">{a.hint}</span>}
                  </button>
                )
              })}
            </section>
          )}
        </div>

        <footer className="se-footer">
          <span className="se-footer-count">
            {showIdle ? 'Type to search' : loading ? 'Searching…' : `${totalCount} result${totalCount === 1 ? '' : 's'}`}
          </span>
          <span className="se-footer-keys">
            <kbd>↵</kbd> open
            <kbd>esc</kbd> close
          </span>
        </footer>
      </div>
    </div>
  )
}
