import { useState, useEffect, useMemo } from 'react'
import type { SearchResult } from '@common/types'
import { IPC } from '@common/ipc'
import './SearchSidebar.css'

interface Props {
  projectPath: string
  onOpenFile: (path: string, line?: number) => void
}

function fileName(path: string): string {
  return path.split(/[\\/]/).pop() || path
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
      <mark className="ss-mark">{text.slice(idx, idx + q.length)}</mark>
      {text.slice(idx + q.length)}
    </>
  )
}

export function SearchSidebar({ projectPath, onOpenFile }: Props): JSX.Element {
  const [query, setQuery] = useState('')
  const [caseSensitive, setCaseSensitive] = useState(false)
  const [wholeWord, setWholeWord] = useState(false)
  const [useRegex, setUseRegex] = useState(false)
  const [results, setResults] = useState<SearchResult[]>([])
  const [replacement, setReplacement] = useState('')
  const [showReplace, setShowReplace] = useState(false)
  const [loading, setLoading] = useState(false)
  const [expanded, setExpanded] = useState<Record<string, boolean>>({})

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
        const r = await (window as any).electron.ipcRenderer.invoke(IPC.SEARCH_PROJECT, projectPath, {
          query,
          caseSensitive,
          wholeWord,
          regex: useRegex
        })
        if (!cancelled) {
          setResults(r)
          const next: Record<string, boolean> = {}
          for (const item of r) next[item.path] = true
          setExpanded(next)
        }
      } catch {
        if (!cancelled) setResults([])
      } finally {
        if (!cancelled) setLoading(false)
      }
    }, 280)
    return () => { cancelled = true; clearTimeout(t) }
  }, [query, caseSensitive, wholeWord, useRegex, projectPath])

  const grouped = useMemo(() => {
    const map = new Map<string, SearchResult[]>()
    for (const r of results) {
      const list = map.get(r.path) || []
      list.push(r)
      map.set(r.path, list)
    }
    return Array.from(map.entries())
  }, [results])

  const replaceAll = async (): Promise<void> => {
    if (!query || !replacement) return
    await (window as any).electron.ipcRenderer.invoke(IPC.SEARCH_REPLACE, projectPath, {
      query,
      caseSensitive,
      wholeWord,
      regex: useRegex
    }, replacement)
    setResults([])
  }

  const toggleFile = (path: string): void => {
    setExpanded((prev) => ({ ...prev, [path]: !prev[path] }))
  }

  return (
    <div className="ss">
      <div className="ss-header">
        <span>Search</span>
        <button
          type="button"
          className={`ss-header-btn ${showReplace ? 'active' : ''}`}
          title="Toggle Replace"
          onClick={() => setShowReplace((v) => !v)}
        >
          <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round">
            <path d="M3 5h8M9 2l3 3-3 3" /><path d="M13 11H5M7 8l-3 3 3 3" />
          </svg>
        </button>
      </div>

      <div className="ss-controls">
        <div className="ss-field">
          <svg className="ss-field-icon" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
            <circle cx="6.5" cy="6.5" r="4.5" /><path d="M10 10l4 4" />
          </svg>
          <input
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder="Search"
            autoFocus
          />
          {loading && <span className="ss-spinner" />}
        </div>

        <div className="ss-toggles" role="group" aria-label="Search options">
          <button
            type="button"
            className={caseSensitive ? 'active' : ''}
            title="Match Case"
            onClick={() => setCaseSensitive((v) => !v)}
          >
            Aa
          </button>
          <button
            type="button"
            className={wholeWord ? 'active' : ''}
            title="Words"
            onClick={() => setWholeWord((v) => !v)}
          >
            W
          </button>
          <button
            type="button"
            className={useRegex ? 'active' : ''}
            title="Regex"
            onClick={() => setUseRegex((v) => !v)}
          >
            .*
          </button>
        </div>

        {showReplace && (
          <div className="ss-replace">
            <div className="ss-field">
              <svg className="ss-field-icon" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
                <path d="M3 5h8M9 2l3 3-3 3" /><path d="M13 11H5M7 8l-3 3 3 3" />
              </svg>
              <input
                value={replacement}
                onChange={(e) => setReplacement(e.target.value)}
                placeholder="Replace"
              />
            </div>
            <button
              type="button"
              className="ss-replace-btn"
              onClick={replaceAll}
              disabled={!query || !replacement}
            >
              Replace All
            </button>
          </div>
        )}
      </div>

      <div className="ss-meta">
        {!query.trim() && <span>Enter a search term</span>}
        {query.trim() && loading && <span>Searching…</span>}
        {query.trim() && !loading && (
          <span>
            {results.length} match{results.length === 1 ? '' : 'es'}
            {grouped.length > 0 && ` in ${grouped.length} file${grouped.length === 1 ? '' : 's'}`}
          </span>
        )}
      </div>

      <div className="ss-results">
        {query.trim() && !loading && results.length === 0 && (
          <div className="ss-empty">No matches found</div>
        )}

        {grouped.map(([path, items]) => {
          const open = expanded[path] !== false
          return (
            <div key={path} className="ss-file">
              <button type="button" className="ss-file-head" onClick={() => toggleFile(path)}>
                <span className={`ss-chevron ${open ? 'open' : ''}`}>▸</span>
                <span className="ss-file-name">{fileName(path)}</span>
                <span className="ss-file-count">{items.length}</span>
              </button>
              {open && (
                <div className="ss-matches">
                  {items.map((r, i) => (
                    <button
                      key={`${path}-${r.line}-${i}`}
                      type="button"
                      className="ss-match"
                      onClick={() => onOpenFile(r.path, r.line)}
                      title={path}
                    >
                      <span className="ss-match-line">{r.line ?? '—'}</span>
                      <span className="ss-match-preview">{highlightMatch(r.preview.trim(), query)}</span>
                    </button>
                  ))}
                </div>
              )}
            </div>
          )
        })}
      </div>
    </div>
  )
}
