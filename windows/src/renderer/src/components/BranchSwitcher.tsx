import { useEffect, useMemo, useRef, useState } from 'react'
import './BranchSwitcher.css'

interface Branch {
  name: string
  hash: string
  isCurrent: boolean
}

interface Props {
  projectPath: string
  branchName: string
  onBranchChange: (name: string) => void
  onClose: () => void
  anchorRef?: React.RefObject<HTMLElement | null>
}

export function BranchSwitcher({
  projectPath,
  branchName,
  onBranchChange,
  onClose
}: Props): JSX.Element {
  const [branches, setBranches] = useState<Branch[]>([])
  const [query, setQuery] = useState('')
  const [newName, setNewName] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const rootRef = useRef<HTMLDivElement>(null)
  const inputRef = useRef<HTMLInputElement>(null)

  const refresh = async (): Promise<void> => {
    try {
      const list = await window.api.gitBranchList(projectPath)
      setBranches(list.filter((b) => !b.name.startsWith('remotes/')))
    } catch (e: any) {
      setError(e?.message || String(e))
    }
  }

  useEffect(() => {
    void refresh()
    requestAnimationFrame(() => inputRef.current?.focus())
  }, [projectPath])

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
    if (!q) return branches
    return branches.filter((b) => b.name.toLowerCase().includes(q))
  }, [branches, query])

  const checkout = async (name: string): Promise<void> => {
    if (name === branchName) {
      onClose()
      return
    }
    setBusy(true)
    setError(null)
    try {
      await window.api.gitBranchSwitch(projectPath, name)
      onBranchChange(name)
      onClose()
    } catch (e: any) {
      setError(e?.message || String(e))
    } finally {
      setBusy(false)
    }
  }

  const create = async (): Promise<void> => {
    const name = newName.trim()
    if (!name) return
    setBusy(true)
    setError(null)
    try {
      await window.api.gitBranchCreate(projectPath, name, true)
      onBranchChange(name)
      onClose()
    } catch (e: any) {
      setError(e?.message || String(e))
    } finally {
      setBusy(false)
    }
  }

  const remove = async (name: string): Promise<void> => {
    if (name === branchName) return
    if (!window.confirm(`Delete branch “${name}”?`)) return
    setBusy(true)
    try {
      await window.api.gitBranchDelete(projectPath, name, false)
      await refresh()
    } catch (e: any) {
      setError(e?.message || String(e))
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="branch-switcher" ref={rootRef} role="dialog" aria-label="Branches">
      <div className="branch-switcher-search">
        <input
          ref={inputRef}
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          placeholder="Filter branches…"
          disabled={busy}
        />
      </div>
      <div className="branch-switcher-list">
        {filtered.map((b) => (
          <div key={b.name} className={`branch-row ${b.isCurrent ? 'current' : ''}`}>
            <button
              type="button"
              className="branch-row-main"
              disabled={busy}
              onClick={() => void checkout(b.name)}
            >
              <span className="branch-dot" />
              <span className="branch-name">{b.name}</span>
              <span className="branch-hash">{b.hash}</span>
            </button>
            {!b.isCurrent && (
              <button
                type="button"
                className="branch-del"
                title="Delete"
                disabled={busy}
                onClick={() => void remove(b.name)}
              >
                ×
              </button>
            )}
          </div>
        ))}
        {filtered.length === 0 && <div className="branch-empty">No branches</div>}
      </div>
      <div className="branch-switcher-create">
        <input
          value={newName}
          onChange={(e) => setNewName(e.target.value)}
          placeholder="New branch name"
          disabled={busy}
          onKeyDown={(e) => e.key === 'Enter' && void create()}
        />
        <button type="button" disabled={busy || !newName.trim()} onClick={() => void create()}>
          Create
        </button>
      </div>
      {error && <div className="branch-error">{error}</div>}
    </div>
  )
}
