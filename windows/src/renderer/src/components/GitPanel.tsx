import { useState, useEffect, useCallback } from 'react'
import type { GitStatus, GitLogEntry } from '@common/types'
import { GitGraphView } from './GitGraphView'
import './GitPanel.css'

interface Props {
  projectPath: string
  onOpenDiff: (file: string, staged: boolean) => void
}

type Tab = 'changes' | 'shelf' | 'log'

interface StashEntry {
  index: number
  ref: string
  message: string
  date: string
}

export function GitPanel({ projectPath, onOpenDiff }: Props): JSX.Element {
  const [tab, setTab] = useState<Tab>('changes')
  const [status, setStatus] = useState<GitStatus | null>(null)
  const [log, setLog] = useState<GitLogEntry[]>([])
  const [stashes, setStashes] = useState<StashEntry[]>([])
  const [commitMsg, setCommitMsg] = useState('')
  const [amend, setAmend] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  const refresh = useCallback(async () => {
    try {
      setError(null)
      const s = await window.api.gitStatus(projectPath)
      if (!s) {
        setError('Not a git repository')
        setStatus(null)
        return
      }
      setStatus(s)
    } catch {
      setError('Not a git repository')
      setStatus(null)
    }
  }, [projectPath])

  const refreshStash = useCallback(async () => {
    try {
      setStashes(await window.api.gitStashList(projectPath))
    } catch {
      setStashes([])
    }
  }, [projectPath])

  useEffect(() => {
    void refresh()
  }, [refresh])

  useEffect(() => {
    if (tab === 'log') {
      void window.api.gitLog(projectPath, 200).then(setLog).catch(() => setLog([]))
    }
    if (tab === 'shelf') void refreshStash()
  }, [tab, projectPath, refreshStash])

  const stage = async (file: string): Promise<void> => {
    await window.api.gitStage(projectPath, [file])
    void refresh()
  }
  const unstage = async (file: string): Promise<void> => {
    await window.api.gitUnstage(projectPath, [file])
    void refresh()
  }
  const discard = async (file: string): Promise<void> => {
    if (!window.confirm(`Discard changes in “${file}”? This cannot be undone.`)) return
    setBusy(true)
    try {
      await window.api.gitDiscard(projectPath, [file])
      void refresh()
    } catch (e: any) {
      setError(e?.message || String(e))
    } finally {
      setBusy(false)
    }
  }
  const commit = async (): Promise<void> => {
    if (!commitMsg.trim() && !amend) return
    setBusy(true)
    try {
      await window.api.gitCommit(projectPath, commitMsg.trim() || 'Amend', amend)
      setCommitMsg('')
      setAmend(false)
      void refresh()
    } catch (e: any) {
      setError(e?.message || String(e))
    } finally {
      setBusy(false)
    }
  }
  const stashSave = async (): Promise<void> => {
    setBusy(true)
    try {
      await window.api.gitStashSave(projectPath, commitMsg.trim() || undefined)
      setCommitMsg('')
      void refresh()
      void refreshStash()
      setTab('shelf')
    } catch (e: any) {
      setError(e?.message || String(e))
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="git-panel">
      <div className="git-tabs">
        <button type="button" className={tab === 'changes' ? 'active' : ''} onClick={() => setTab('changes')}>
          Changes
        </button>
        <button type="button" className={tab === 'shelf' ? 'active' : ''} onClick={() => setTab('shelf')}>
          Shelf
          {stashes.length > 0 ? <em>{stashes.length}</em> : null}
        </button>
        <button type="button" className={tab === 'log' ? 'active' : ''} onClick={() => setTab('log')}>
          Log
        </button>
        <span className="git-branch">{status?.branch}</span>
      </div>

      {error && <div className="git-error">{error}</div>}

      {tab === 'changes' && status && (
        <div className="git-changes">
          <div className="git-section-title">Staged</div>
          {status.staged.map((c) => (
            <div key={`s-${c.path}`} className="git-file" onClick={() => onOpenDiff(c.path, true)}>
              <span className={`git-status-badge st-${c.status}`}>{c.status[0].toUpperCase()}</span>
              <span className="git-file-name">{c.path}</span>
              <button type="button" className="git-action" title="Unstage" onClick={(e) => { e.stopPropagation(); void unstage(c.path) }}>
                &minus;
              </button>
            </div>
          ))}
          {status.staged.length === 0 && <div className="git-empty">No staged changes</div>}

          <div className="git-section-title">Unstaged</div>
          {status.unstaged.map((c) => (
            <div key={`u-${c.path}`} className="git-file" onClick={() => onOpenDiff(c.path, false)}>
              <span className={`git-status-badge st-${c.status}`}>{c.status[0].toUpperCase()}</span>
              <span className="git-file-name">{c.path}</span>
              <button type="button" className="git-action" title="Stage" onClick={(e) => { e.stopPropagation(); void stage(c.path) }}>
                +
              </button>
              <button type="button" className="git-action danger" title="Discard" disabled={busy} onClick={(e) => { e.stopPropagation(); void discard(c.path) }}>
                ↺
              </button>
            </div>
          ))}
          {status.untracked.map((f) => (
            <div key={`t-${f}`} className="git-file">
              <span className="git-status-badge st-added">U</span>
              <span className="git-file-name">{f}</span>
              <button type="button" className="git-action" title="Stage" onClick={() => void stage(f)}>
                +
              </button>
              <button type="button" className="git-action danger" title="Delete untracked" disabled={busy} onClick={() => void discard(f)}>
                ↺
              </button>
            </div>
          ))}
          {status.unstaged.length === 0 && status.untracked.length === 0 && (
            <div className="git-empty">No unstaged changes</div>
          )}

          <div className="git-commit-box">
            <textarea
              placeholder="Commit message…"
              value={commitMsg}
              onChange={(e) => setCommitMsg(e.target.value)}
            />
            <label className="git-amend">
              <input type="checkbox" checked={amend} onChange={(e) => setAmend(e.target.checked)} />
              Amend
            </label>
            <div className="git-commit-actions">
              <button
                type="button"
                className="git-commit-btn ghost"
                disabled={busy}
                onClick={() => void stashSave()}
                title="Stash including untracked"
              >
                Shelf
              </button>
              <button
                type="button"
                className="git-commit-btn"
                onClick={() => void commit()}
                disabled={busy || (!amend && (!commitMsg.trim() || status.staged.length === 0))}
              >
                {amend ? 'Amend Commit' : 'Commit'}
              </button>
            </div>
          </div>
        </div>
      )}

      {tab === 'shelf' && (
        <div className="git-changes">
          <div className="git-section-title">Shelved changes (git stash)</div>
          {stashes.length === 0 && <div className="git-empty">No shelved changes</div>}
          {stashes.map((s) => (
            <div key={s.ref} className="git-stash-row">
              <div className="git-stash-main">
                <strong>{s.ref}</strong>
                <span>{s.message || 'WIP'}</span>
                {s.date ? <em>{new Date(s.date).toLocaleString()}</em> : null}
              </div>
              <div className="git-stash-actions">
                <button
                  type="button"
                  className="git-action"
                  disabled={busy}
                  title="Apply"
                  onClick={() => {
                    void (async () => {
                      setBusy(true)
                      try {
                        await window.api.gitStashApply(projectPath, s.index, false)
                        void refresh()
                        void refreshStash()
                      } catch (e: any) {
                        setError(e?.message || String(e))
                      } finally {
                        setBusy(false)
                      }
                    })()
                  }}
                >
                  Apply
                </button>
                <button
                  type="button"
                  className="git-action"
                  disabled={busy}
                  title="Pop"
                  onClick={() => {
                    void (async () => {
                      setBusy(true)
                      try {
                        await window.api.gitStashApply(projectPath, s.index, true)
                        void refresh()
                        void refreshStash()
                      } catch (e: any) {
                        setError(e?.message || String(e))
                      } finally {
                        setBusy(false)
                      }
                    })()
                  }}
                >
                  Pop
                </button>
                <button
                  type="button"
                  className="git-action danger"
                  disabled={busy}
                  title="Drop"
                  onClick={() => {
                    if (!window.confirm(`Drop ${s.ref}?`)) return
                    void (async () => {
                      setBusy(true)
                      try {
                        await window.api.gitStashDrop(projectPath, s.index)
                        void refreshStash()
                      } catch (e: any) {
                        setError(e?.message || String(e))
                      } finally {
                        setBusy(false)
                      }
                    })()
                  }}
                >
                  Drop
                </button>
              </div>
            </div>
          ))}
        </div>
      )}

      {tab === 'log' && (
        <div className="git-log">
          <GitGraphView commits={log} />
        </div>
      )}
    </div>
  )
}
