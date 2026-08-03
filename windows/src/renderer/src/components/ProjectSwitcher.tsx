import { useEffect, useMemo, useRef, useState } from 'react'
import type { RecentProject } from '@common/types'
import './ProjectSwitcher.css'

interface Props {
  currentPath: string
  onOpen: (path: string) => void
  onCloseProject: () => void
  onClose: () => void
}

export function ProjectSwitcher({
  currentPath,
  onOpen,
  onCloseProject,
  onClose
}: Props): JSX.Element {
  const [recent, setRecent] = useState<RecentProject[]>([])
  const [query, setQuery] = useState('')
  const rootRef = useRef<HTMLDivElement>(null)
  const inputRef = useRef<HTMLInputElement>(null)

  useEffect(() => {
    void window.api.recentList().then(setRecent)
    requestAnimationFrame(() => inputRef.current?.focus())
  }, [])

  useEffect(() => {
    const onDoc = (e: MouseEvent): void => {
      if (!rootRef.current?.contains(e.target as Node)) onClose()
    }
    const onKey = (e: KeyboardEvent): void => {
      if (e.key === 'Escape') onClose()
    }
    document.addEventListener('mousedown', onDoc)
    document.addEventListener('keydown', onKey)
    return () => {
      document.removeEventListener('mousedown', onDoc)
      document.removeEventListener('keydown', onKey)
    }
  }, [onClose])

  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase()
    if (!q) return recent
    return recent.filter(
      (p) => p.name.toLowerCase().includes(q) || p.path.toLowerCase().includes(q)
    )
  }, [recent, query])

  return (
    <div className="project-switcher" ref={rootRef} role="dialog" aria-label="Projects">
      <div className="project-switcher-search">
        <input
          ref={inputRef}
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          placeholder="Filter recent projects…"
        />
      </div>
      <div className="project-switcher-list">
        {filtered.map((p) => (
          <button
            key={p.path}
            type="button"
            className={`project-row ${p.path === currentPath ? 'current' : ''}`}
            onClick={() => {
              if (p.path !== currentPath) onOpen(p.path)
              onClose()
            }}
          >
            <strong>{p.name}</strong>
            <span>{p.path}</span>
          </button>
        ))}
        {filtered.length === 0 && <div className="project-empty">No recent projects</div>}
      </div>
      <div className="project-switcher-foot">
        <button
          type="button"
          onClick={() => {
            void window.api.openProjectDialog().then((dir) => {
              if (dir) {
                onOpen(dir)
                onClose()
              }
            })
          }}
        >
          Open…
        </button>
        <button type="button" className="ghost" onClick={() => { onCloseProject(); onClose() }}>
          Close Project
        </button>
      </div>
    </div>
  )
}
