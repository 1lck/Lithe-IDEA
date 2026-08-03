import { useEffect, useRef, useState } from 'react'
import { ToolWindowHeader } from './ToolWindowHeader'
import './PluginToolWindowPanel.css'

interface TitleButton {
  command: string
  title: string
  codicon?: string
  iconDataUrl?: string
  order: number
}

interface Props {
  title: string
  pluginName: string
  pluginKind: string
  pluginId: string
  projectPath?: string
  synthetic?: boolean
  hasWebviewUi?: boolean
  note?: string
  titleButtons?: TitleButton[]
  onMinimize: () => void
  onOpenPlugins: () => void
}

/** Hosts a VS Code-style sidebar webview; prefers Extension Host when available. */
export function PluginToolWindowPanel({
  title,
  pluginName,
  pluginKind,
  pluginId,
  projectPath,
  synthetic,
  hasWebviewUi,
  note,
  titleButtons,
  onMinimize,
  onOpenPlugins
}: Props): JSX.Element {
  const kindLabel =
    pluginKind === 'idea' ? 'JetBrains' : pluginKind === 'vscode' ? 'VS Code' : 'Lithe'

  const frameRef = useRef<HTMLIFrameElement | null>(null)
  const [webviewUrl, setWebviewUrl] = useState<string | null>(null)
  const [webviewError, setWebviewError] = useState<string | null>(null)
  const [hostNote, setHostNote] = useState<string | null>(null)
  const [loading, setLoading] = useState(false)

  useEffect(() => {
    let cancelled = false
    setWebviewUrl(null)
    setWebviewError(null)
    setHostNote(null)

    if (!hasWebviewUi || pluginKind !== 'vscode') {
      setLoading(false)
      return
    }

    setLoading(true)
    void window.api
      .pluginWebviewUrl(pluginId, projectPath)
      .then((res) => {
        if (cancelled) return
        if (res.ok) {
          setWebviewUrl(res.url)
          if (res.hostStatus === 'running') {
            setHostNote('Extension Host connected')
          } else if (res.hostError) {
            setHostNote(`Host fallback: ${res.hostError}`)
          } else {
            setHostNote('UI preview mode (host idle)')
          }
        } else {
          setWebviewError(res.error || 'Webview unavailable')
        }
      })
      .catch((err: any) => {
        if (!cancelled) setWebviewError(err?.message || String(err))
      })
      .finally(() => {
        if (!cancelled) setLoading(false)
      })

    return () => {
      cancelled = true
    }
  }, [hasWebviewUi, pluginId, pluginKind, projectPath])

  // iframe → Extension Host, and Host → iframe
  useEffect(() => {
    if (!webviewUrl) return

    const onWindowMsg = (e: MessageEvent): void => {
      if (!e.data?.__lithePlugin || e.data.pluginId !== pluginId) return
      if (e.data.direction !== 'to-host') return
      const data = e.data.data
      if (!data || typeof data !== 'object') return
      void window.api.pluginHostPost(pluginId, data)
    }
    window.addEventListener('message', onWindowMsg)

    const off = window.api.onPluginHostEvent((payload) => {
      if (payload.pluginId !== pluginId) return
      frameRef.current?.contentWindow?.postMessage(payload.message, '*')
    })

    return () => {
      window.removeEventListener('message', onWindowMsg)
      off()
    }
  }, [webviewUrl, pluginId])

  return (
    <div className="plugin-tool-window">
      <ToolWindowHeader title={title} subtitle={pluginName} onMinimize={onMinimize}>
        {titleButtons?.map((btn) => (
          <button
            key={btn.command}
            type="button"
            className="plugin-view-title-btn"
            title={btn.title}
            aria-label={btn.title}
            onClick={() => {
              void (window.api as any).pluginExecuteCommand?.(pluginId, btn.command)
            }}
          >
            {btn.iconDataUrl ? (
              <img src={btn.iconDataUrl} alt="" draggable={false} />
            ) : btn.codicon ? (
              <i className={`codicon codicon-${btn.codicon}`} aria-hidden />
            ) : (
              <span className="plugin-view-title-btn-text">{btn.title.slice(0, 1).toUpperCase()}</span>
            )}
          </button>
        ))}
        {hostNote ? <span className="plugin-host-chip" title={hostNote}>{hostNote}</span> : null}
      </ToolWindowHeader>
      {webviewUrl ? (
        <iframe
          ref={frameRef}
          className="plugin-tool-frame"
          title={title}
          src={webviewUrl}
          allow="clipboard-read; clipboard-write"
        />
      ) : (
        <div className="plugin-tool-body">
          {loading ? (
            <p>Starting plugin host & loading UI…</p>
          ) : (
            <>
              <h3>{title}</h3>
              <p>
                {webviewError
                  ? webviewError
                  : synthetic
                    ? `${pluginName} is installed but has no hostable webview UI.`
                    : `${pluginName} declared this tool window.`}
              </p>
              <p className="plugin-tool-note">
                {note ||
                  (pluginKind === 'idea'
                    ? 'JetBrains plugin UI is not executed yet.'
                    : 'VS Code Extension Host could not present this view.')}
              </p>
              <div className="plugin-tool-meta">
                <span>{kindLabel}</span>
                <span>{pluginId}</span>
              </div>
              <button type="button" className="plugin-tool-manage" onClick={onOpenPlugins}>
                Manage Plugins
              </button>
            </>
          )}
        </div>
      )}
    </div>
  )
}
