import { useEffect, useMemo, useState } from 'react'
import './CloneRepositoryView.css'

interface Props {
  onClose: () => void
  onCloned: (path: string) => void
}

function guessFolderName(url: string): string {
  const cleaned = url.trim().replace(/\.git$/i, '')
  const parts = cleaned.split(/[/\\]/).filter(Boolean)
  return parts[parts.length - 1] || 'project'
}

export function CloneRepositoryView({ onClose, onCloned }: Props): JSX.Element {
  const [remoteURL, setRemoteURL] = useState('')
  const [parentFolder, setParentFolder] = useState('')
  const [folderName, setFolderName] = useState('')
  const [progress, setProgress] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    // Soft default — user can Choose… to pick another folder
    setParentFolder('')
  }, [])

  useEffect(() => {
    const name = guessFolderName(remoteURL)
    if (name && !folderName) setFolderName(name)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [remoteURL])

  useEffect(() => {
    window.api.onGitCloneProgress((msg) => {
      const line = String(msg).trim().split('\n').pop()
      if (line) setProgress(line)
    })
    return () => window.api.removeAllListeners('git:clone-progress')
  }, [])

  const destination = useMemo(() => {
    const parent = parentFolder.trim().replace(/[/\\]+$/, '')
    const name = folderName.trim()
    if (!parent || !name) return ''
    return `${parent}\\${name}`
  }, [parentFolder, folderName])

  const chooseParent = async (): Promise<void> => {
    const dir = await window.api.pickDirectory()
    if (dir) setParentFolder(dir)
  }

  const clone = async (): Promise<void> => {
    setError(null)
    const url = remoteURL.trim()
    if (!url) {
      setError('Enter a repository URL')
      return
    }
    if (!destination) {
      setError('Choose a destination folder and name')
      return
    }
    setBusy(true)
    setProgress('Starting clone…')
    try {
      await window.api.gitClone(url, destination)
      onCloned(destination)
    } catch (e: any) {
      setError(e?.message || String(e))
      setProgress(null)
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="clone-overlay" onClick={onClose}>
      <div className="clone-shell" onClick={(e) => e.stopPropagation()}>
        <header className="clone-header">
          <div>
            <h2>Clone Repository</h2>
            <p>Clone a Git remote into a local folder and open it in Lithe</p>
          </div>
          <button type="button" className="clone-close" onClick={onClose} aria-label="Close">
            ×
          </button>
        </header>

        <div className="clone-body">
          <label className="clone-field">
            <span>Repository URL</span>
            <input
              autoFocus
              value={remoteURL}
              onChange={(e) => setRemoteURL(e.target.value)}
              placeholder="https://github.com/example/project.git"
              disabled={busy}
            />
          </label>

          <label className="clone-field">
            <span>Destination folder</span>
            <div className="clone-row">
              <input
                value={parentFolder}
                onChange={(e) => setParentFolder(e.target.value)}
                placeholder="C:\Users\…\Projects"
                disabled={busy}
              />
              <button type="button" className="clone-btn" disabled={busy} onClick={() => void chooseParent()}>
                Choose…
              </button>
            </div>
          </label>

          <label className="clone-field">
            <span>Folder name</span>
            <input
              value={folderName}
              onChange={(e) => setFolderName(e.target.value)}
              placeholder="project-name"
              disabled={busy}
              onKeyDown={(e) => e.key === 'Enter' && void clone()}
            />
          </label>

          <p className="clone-dest">
            {destination
              ? `Lithe will clone into ${destination}`
              : 'Pick a parent folder and name to see the destination path.'}
          </p>

          {progress && <pre className="clone-progress">{progress}</pre>}
          {error && <div className="clone-error">{error}</div>}
        </div>

        <footer className="clone-footer">
          <button type="button" className="clone-btn" disabled={busy} onClick={onClose}>
            Cancel
          </button>
          <button type="button" className="clone-btn primary" disabled={busy} onClick={() => void clone()}>
            {busy ? 'Cloning…' : 'Clone'}
          </button>
        </footer>
      </div>
    </div>
  )
}
