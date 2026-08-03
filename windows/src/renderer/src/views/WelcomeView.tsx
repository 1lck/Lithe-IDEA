import { useMemo, useState } from 'react'
import type { RecentProject } from '@common/types'
import { SettingsView } from './SettingsView'
import { PluginsView } from './PluginsView'
import { CloneRepositoryView } from './CloneRepositoryView'
import './WelcomeView.css'

interface Props {
  recentProjects: RecentProject[]
  onOpenProject: (path?: string) => void
  onRemoveRecent: (path: string) => void
}

function initials(name: string): string {
  const words = name.split(/[^a-zA-Z0-9]+/).filter(Boolean)
  const chars = words.slice(0, 2).map((w) => w[0])
  return chars.length ? chars.join('').toUpperCase() : 'LI'
}

function colorIndex(name: string): number {
  let hash = 0
  for (let i = 0; i < name.length; i++) {
    hash = ((hash << 5) - hash + name.charCodeAt(i)) | 0
  }
  return Math.abs(hash) % 5
}

function shortenPath(p: string): string {
  return p.replace(/^([A-Za-z]:\\)?Users\\[^\\]+/i, '~').replace(/\\/g, '/')
}

export function WelcomeView({ recentProjects, onOpenProject, onRemoveRecent }: Props): JSX.Element {
  const [query, setQuery] = useState('')
  const [settingsOpen, setSettingsOpen] = useState(false)
  const [pluginsOpen, setPluginsOpen] = useState(false)
  const [cloneOpen, setCloneOpen] = useState(false)

  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase()
    if (!q) return recentProjects
    return recentProjects.filter(
      (p) => p.name.toLowerCase().includes(q) || p.path.toLowerCase().includes(q)
    )
  }, [recentProjects, query])

  return (
    <div className="welcome">
      <div className="welcome-banner lithe-drag">
        <span>Welcome to Lithe</span>
      </div>

      <div className="welcome-content">
        <aside className="welcome-left">
          <div className="welcome-brand">
            <div className="welcome-logo" aria-hidden="true">
              <span className="welcome-logo-bracket">&lt;</span>
              <span className="welcome-logo-letter">L</span>
              <span className="welcome-logo-bracket">&gt;</span>
            </div>
            <div className="welcome-brand-text">
              <h1>Lithe</h1>
              <span>0.1.0 · Windows</span>
            </div>
          </div>

          <nav className="welcome-nav">
            <button className="welcome-nav-item active" type="button">
              <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round">
                <path d="M2 5l6-3 6 3v6l-6 3-6-3V5z" /><path d="M2 5l6 3 6-3" /><path d="M8 8v6" />
              </svg>
              Projects
            </button>
          </nav>

          <div className="welcome-sidebar-spacer" />

          <button
            className="welcome-settings lithe-no-drag"
            type="button"
            onClick={() => setSettingsOpen(true)}
          >
            <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.3" strokeLinecap="round" strokeLinejoin="round">
              <circle cx="8" cy="8" r="2.5" /><path d="M13.5 8a5.5 5.5 0 01-.4 1.5l1 1.2-1.4 1.4-1.2-1a5.5 5.5 0 01-3 0l-1.2 1-1.4-1.4 1-1.2a5.5 5.5 0 010-3l-1-1.2 1.4-1.4 1.2 1a5.5 5.5 0 013 0l1.2-1 1.4 1.4-1 1.2A5.5 5.5 0 0113.5 8z" />
            </svg>
            Settings
          </button>
        </aside>

        <main className="welcome-right">
          <div className="welcome-toolbar lithe-no-drag">
            <div className="welcome-search">
              <svg className="welcome-search-icon" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
                <circle cx="6.5" cy="6.5" r="4.5" /><path d="M10 10l4 4" />
              </svg>
              <input
                placeholder="Search projects"
                value={query}
                onChange={(e) => setQuery(e.target.value)}
              />
            </div>
            <div className="welcome-toolbar-spacer" />
            <button className="welcome-btn-ghost" type="button" onClick={() => setCloneOpen(true)}>
              Clone
            </button>
            <button className="welcome-btn-open" type="button" onClick={() => onOpenProject()}>
              Open
            </button>
          </div>

          {recentProjects.length === 0 ? (
            <div className="welcome-empty">
              <h3>No recent projects</h3>
              <p>Open a local folder to start.</p>
              <button className="welcome-btn-open" type="button" onClick={() => onOpenProject()}>
                Open project
              </button>
            </div>
          ) : filtered.length === 0 ? (
            <div className="welcome-empty">
              <h3>No matches</h3>
              <p>Try a different name or path.</p>
            </div>
          ) : (
            <ul className="recent-list">
              {filtered.map((p) => (
                <li key={p.path} className="recent-item">
                  <button className="recent-link" type="button" onClick={() => onOpenProject(p.path)}>
                    <span className={`recent-avatar recent-avatar-${colorIndex(p.name)}`}>
                      {initials(p.name)}
                    </span>
                    <div className="recent-info">
                      <div className="recent-name">{p.name}</div>
                      <div className="recent-path">{shortenPath(p.path)}</div>
                    </div>
                  </button>
                  <button
                    className="recent-remove"
                    type="button"
                    title="Remove from recent"
                    onClick={(e) => { e.stopPropagation(); onRemoveRecent(p.path) }}
                  >
                    ⋯
                  </button>
                </li>
              ))}
            </ul>
          )}
        </main>
      </div>

      {settingsOpen && (
        <SettingsView
          onClose={() => setSettingsOpen(false)}
          onOpenPlugins={() => {
            setSettingsOpen(false)
            setPluginsOpen(true)
          }}
        />
      )}
      {pluginsOpen && <PluginsView onClose={() => setPluginsOpen(false)} />}
      {cloneOpen && (
        <CloneRepositoryView
          onClose={() => setCloneOpen(false)}
          onCloned={(path) => {
            setCloneOpen(false)
            onOpenProject(path)
          }}
        />
      )}
    </div>
  )
}
