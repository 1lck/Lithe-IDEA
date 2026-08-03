import { useState, useEffect, useCallback } from 'react'
import './LocalHistoryPanel.css'

interface HistoryEntry {
  timestamp: number
  fileName: string
}

interface Props {
  filePath: string | null
  onRestored?: (path: string, content: string) => void
}

export function LocalHistoryPanel({ filePath, onRestored }: Props): JSX.Element {
  const [entries, setEntries] = useState<HistoryEntry[]>([])
  const [selected, setSelected] = useState<string | null>(null)
  const [selectedContent, setSelectedContent] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [status, setStatus] = useState<string | null>(null)

  const refresh = useCallback(async (): Promise<void> => {
    if (!filePath) {
      setEntries([])
      return
    }
    const list = await window.api.localHistoryList(filePath)
    setEntries(list)
  }, [filePath])

  useEffect(() => {
    setSelected(null)
    setSelectedContent(null)
    setStatus(null)
    void refresh()
  }, [refresh])

  const viewEntry = useCallback(async (fileName: string) => {
    setSelected(fileName)
    const entry = await window.api.localHistoryGet(fileName)
    setSelectedContent(entry.content)
  }, [])

  const restore = async (): Promise<void> => {
    if (!selected || !filePath) return
    if (!window.confirm('Restore this revision? Current disk content will be snapshotted first.')) return
    setBusy(true)
    try {
      const entry = await window.api.localHistoryRestore(selected)
      onRestored?.(entry.path, entry.content)
      setSelectedContent(entry.content)
      setStatus('Restored · previous content saved to Local History')
      await refresh()
    } catch (e: any) {
      setStatus(e?.message || String(e))
    } finally {
      setBusy(false)
    }
  }

  if (!filePath) {
    return (
      <div className="local-history-panel">
        <div className="lh-header">LOCAL HISTORY</div>
        <div className="lh-empty">Select a file to view its local history</div>
      </div>
    )
  }

  return (
    <div className="local-history-panel">
      <div className="lh-header">
        <span>LOCAL HISTORY</span>
        {selected && (
          <button type="button" className="lh-restore" disabled={busy} onClick={() => void restore()}>
            {busy ? 'Restoring…' : 'Restore'}
          </button>
        )}
      </div>
      {status && <div className="lh-status">{status}</div>}
      <div className="lh-content">
        <div className="lh-list">
          {entries.length === 0 && <div className="lh-empty">No history for this file</div>}
          {entries.map((e) => (
            <button
              key={e.fileName}
              type="button"
              className={`lh-entry ${selected === e.fileName ? 'active' : ''}`}
              onClick={() => void viewEntry(e.fileName)}
            >
              {new Date(e.timestamp).toLocaleString()}
            </button>
          ))}
        </div>
        {selectedContent !== null ? (
          <pre className="lh-preview">{selectedContent}</pre>
        ) : (
          <div className="lh-empty pad">Select a revision to preview</div>
        )}
      </div>
    </div>
  )
}
