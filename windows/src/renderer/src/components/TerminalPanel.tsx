import { useEffect, useRef, useState, useCallback } from 'react'
import { Terminal } from '@xterm/xterm'
import { FitAddon } from '@xterm/addon-fit'
import '@xterm/xterm/css/xterm.css'
import './TerminalPanel.css'

interface Props {
  cwd: string
}

const PORT_KEY = 'lithe.serve.port'

function loadPort(): number {
  const n = Number(localStorage.getItem(PORT_KEY) || '5500')
  return Number.isFinite(n) && n >= 1 && n <= 65535 ? n : 5500
}

function normalizePaste(text: string): string {
  // ConPTY / shells expect CR as line terminator from the terminal
  return text.replace(/\r\n/g, '\n').replace(/\n/g, '\r')
}

interface CtxMenu {
  x: number
  y: number
  canCopy: boolean
}

export function TerminalPanel({ cwd }: Props): JSX.Element {
  const hostRef = useRef<HTMLDivElement>(null)
  const termRef = useRef<Terminal | null>(null)
  const fitRef = useRef<FitAddon | null>(null)
  const sessionIdRef = useRef<string | null>(null)
  const writePtyRef = useRef<(data: string) => void>(() => undefined)

  const [cwdLabel, setCwdLabel] = useState(cwd)
  const [serverUrl, setServerUrl] = useState<string | null>(null)
  const [serverBusy, setServerBusy] = useState(false)
  const [ready, setReady] = useState(false)
  const [port, setPort] = useState(loadPort)
  const [ctxMenu, setCtxMenu] = useState<CtxMenu | null>(null)

  useEffect(() => {
    void window.api.localServerStatus().then((s) => {
      setServerUrl(s.running && s.url ? s.url : null)
      if (s.port) setPort(s.port)
    })
  }, [])

  useEffect(() => {
    const host = hostRef.current
    if (!host) return

    let disposed = false
    const sessionId = `term-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`
    sessionIdRef.current = sessionId

    const term = new Terminal({
      cursorBlink: true,
      cursorStyle: 'bar',
      fontSize: 13,
      fontFamily: "'JetBrains Mono', 'Cascadia Code', Consolas, monospace",
      lineHeight: 1.3,
      rightClickSelectsWord: false,
      theme: {
        background: '#131416',
        foreground: '#dbdbdb',
        cursor: '#dbdbdb',
        cursorAccent: '#131416',
        selectionBackground: '#2b4a7d',
        black: '#131416',
        red: '#eb5454',
        green: '#47b863',
        yellow: '#e8a133',
        blue: '#4f94fa',
        magenta: '#c77dbb',
        cyan: '#2aacb8',
        white: '#dbdbdb',
        brightBlack: '#575757',
        brightRed: '#eb5454',
        brightGreen: '#47b863',
        brightYellow: '#e8a133',
        brightBlue: '#6badff',
        brightMagenta: '#c77dbb',
        brightCyan: '#2aacb8',
        brightWhite: '#ffffff'
      },
      scrollback: 8000,
      convertEol: false,
      allowProposedApi: true
    })

    const fit = new FitAddon()
    term.loadAddon(fit)
    term.open(host)
    // Ensure the hidden textarea can receive keys
    term.focus()

    try {
      fit.fit()
    } catch { /* ignore */ }

    termRef.current = term
    fitRef.current = fit

    const onData = (payload: { id: string; data: string }): void => {
      if (payload.id !== sessionId || disposed) return
      term.write(payload.data)
    }
    window.api.onTerminalData(onData)

    const writePty = (data: string): void => {
      if (disposed || sessionIdRef.current !== sessionId) return
      void window.api.terminalWrite(sessionId, data).catch((err: any) => {
        if (!disposed) {
          term.writeln(`\r\n\x1b[31m[PTY write failed] ${err?.message || err}\x1b[0m`)
        }
      })
    }
    writePtyRef.current = writePty

    const copySelection = async (): Promise<boolean> => {
      const sel = term.getSelection()
      if (!sel) return false
      try {
        await navigator.clipboard.writeText(sel)
        return true
      } catch {
        return false
      }
    }

    const pasteClipboard = async (): Promise<void> => {
      try {
        const text = await navigator.clipboard.readText()
        if (text) writePty(normalizePaste(text))
      } catch {
        /* clipboard permission denied */
      }
    }

    // Copy / paste shortcuts (Windows + terminal conventions)
    term.attachCustomKeyEventHandler((ev) => {
      if (ev.type !== 'keydown') return true
      const key = ev.key.toLowerCase()
      const mod = ev.ctrlKey || ev.metaKey

      // Ctrl+Shift+C / Ctrl+Insert → copy
      if ((mod && ev.shiftKey && key === 'c') || (ev.ctrlKey && ev.key === 'Insert')) {
        void copySelection()
        return false
      }
      // Ctrl+C with selection → copy (no interrupt); bare Ctrl+C → interrupt
      if (mod && !ev.shiftKey && key === 'c' && term.hasSelection()) {
        void copySelection()
        return false
      }
      // Ctrl+V / Ctrl+Shift+V / Shift+Insert → paste
      if ((mod && key === 'v') || (ev.shiftKey && ev.key === 'Insert')) {
        void pasteClipboard()
        return false
      }
      return true
    })

    // Raw keystrokes → PTY
    const dataDisp = term.onData(writePty)
    const binaryDisp = term.onBinary(writePty)

    // Native paste / copy events (browser / context menu)
    const onPaste = (e: ClipboardEvent): void => {
      e.preventDefault()
      e.stopPropagation()
      const text = e.clipboardData?.getData('text/plain')
      if (text) writePty(normalizePaste(text))
    }
    const onCopy = (e: ClipboardEvent): void => {
      const sel = term.getSelection()
      if (!sel) return
      e.preventDefault()
      e.clipboardData?.setData('text/plain', sel)
    }
    host.addEventListener('paste', onPaste)
    host.addEventListener('copy', onCopy)

    const boot = async (): Promise<void> => {
      try {
        // Wait a frame so layout has real size
        await new Promise<void>((r) => requestAnimationFrame(() => r()))
        if (disposed) return
        try { fit.fit() } catch { /* ignore */ }

        const created = await window.api.terminalCreate(
          sessionId,
          cwd,
          undefined,
          Math.max(term.cols || 80, 40),
          Math.max(term.rows || 24, 12)
        )
        if (disposed) {
          void window.api.terminalDestroy(sessionId)
          return
        }
        setCwdLabel(created.cwd || cwd)
        setReady(true)
        // Focus after shell is ready
        requestAnimationFrame(() => {
          if (!disposed) {
            term.focus()
            try { fit.fit() } catch { /* ignore */ }
            void window.api.terminalResize(sessionId, term.cols, term.rows)
          }
        })
      } catch (err: any) {
        if (disposed) return
        setReady(false)
        term.writeln(`\x1b[31mFailed to start PTY: ${err?.message || err}\x1b[0m`)
        term.writeln('\x1b[90mInteractive tools (Claude Code) need ConPTY. Check node-pty prebuilds.\x1b[0m')
      }
    }
    void boot()

    const ro = new ResizeObserver(() => {
      if (disposed) return
      try {
        fit.fit()
        if (sessionIdRef.current === sessionId) {
          void window.api.terminalResize(sessionId, term.cols, term.rows)
        }
      } catch { /* ignore */ }
    })
    ro.observe(host)

    const onFocusClick = (e: MouseEvent): void => {
      term.focus()
      if (e.button === 0) setCtxMenu(null)
    }
    host.addEventListener('mousedown', onFocusClick)

    const onContextMenu = (e: MouseEvent): void => {
      e.preventDefault()
      e.stopPropagation()
      term.focus()
      setCtxMenu({
        x: e.clientX,
        y: e.clientY,
        canCopy: term.hasSelection()
      })
    }
    host.addEventListener('contextmenu', onContextMenu)

    return () => {
      disposed = true
      if (sessionIdRef.current === sessionId) sessionIdRef.current = null
      host.removeEventListener('mousedown', onFocusClick)
      host.removeEventListener('contextmenu', onContextMenu)
      host.removeEventListener('paste', onPaste)
      host.removeEventListener('copy', onCopy)
      dataDisp.dispose()
      binaryDisp.dispose()
      ro.disconnect()
      void window.api.terminalDestroy(sessionId)
      // Only remove listeners we own — drop all for this channel after destroy
      window.api.removeAllListeners('terminal:data')
      window.api.removeAllListeners('terminal:exit')
      term.dispose()
      if (termRef.current === term) termRef.current = null
      if (fitRef.current === fit) fitRef.current = null
      writePtyRef.current = () => undefined
      setReady(false)
      setCtxMenu(null)
    }
  }, [cwd])

  const focusTerm = useCallback((): void => {
    termRef.current?.focus()
  }, [])

  const copyFromMenu = useCallback(async (): Promise<void> => {
    const term = termRef.current
    const sel = term?.getSelection()
    if (sel) {
      try { await navigator.clipboard.writeText(sel) } catch { /* ignore */ }
    }
    setCtxMenu(null)
    focusTerm()
  }, [focusTerm])

  const pasteFromMenu = useCallback(async (): Promise<void> => {
    try {
      const text = await navigator.clipboard.readText()
      if (text) writePtyRef.current(normalizePaste(text))
    } catch { /* ignore */ }
    setCtxMenu(null)
    focusTerm()
  }, [focusTerm])

  useEffect(() => {
    if (!ctxMenu) return
    const close = (): void => setCtxMenu(null)
    const onKey = (e: KeyboardEvent): void => {
      if (e.key === 'Escape') close()
    }
    window.addEventListener('mousedown', close)
    window.addEventListener('keydown', onKey)
    return () => {
      window.removeEventListener('mousedown', close)
      window.removeEventListener('keydown', onKey)
    }
  }, [ctxMenu])

  const toggleServer = async (): Promise<void> => {
    setServerBusy(true)
    try {
      if (serverUrl) {
        await window.api.localServerStop()
        setServerUrl(null)
        window.dispatchEvent(new Event('lithe:server-changed'))
        termRef.current?.writeln('\r\n\x1b[90m[Local server stopped]\x1b[0m')
      } else {
        const p = Math.min(65535, Math.max(1, Number(port) || 5500))
        setPort(p)
        localStorage.setItem(PORT_KEY, String(p))
        const res = await window.api.localServerStart(cwd, p)
        setServerUrl(res.url)
        setPort(res.port)
        window.dispatchEvent(new Event('lithe:server-changed'))
        termRef.current?.writeln(`\r\n\x1b[32m[Local server] ${res.url}\x1b[0m`)
      }
    } catch (err: any) {
      termRef.current?.writeln(`\r\n\x1b[31m[Server error] ${err?.message || String(err)}\x1b[0m`)
    } finally {
      setServerBusy(false)
      focusTerm()
    }
  }

  return (
    <div className="terminal-panel">
      <div className="terminal-header">
        <div className="terminal-header-left">
          <span className="terminal-title">Terminal</span>
          <span className={`terminal-badge ${ready ? 'ok' : ''}`}>{ready ? 'PTY' : '…'}</span>
          <span className="terminal-cwd" title={cwdLabel}>{cwdLabel}</span>
        </div>
        <div className="terminal-header-actions">
          {!serverUrl && (
            <label className="terminal-port">
              <span>:</span>
              <input
                type="number"
                min={1}
                max={65535}
                value={port}
                onChange={(e) => setPort(Number(e.target.value) || 5500)}
                onKeyDown={(e) => e.stopPropagation()}
                onMouseDown={(e) => e.stopPropagation()}
                title="Serve port"
              />
            </label>
          )}
          {serverUrl ? (
            <>
              <button
                type="button"
                className="terminal-action server-live"
                title="Open in browser"
                onClick={() => void window.api.localServerOpen()}
              >
                {serverUrl.replace(/^https?:\/\//, '')}
              </button>
              <button
                type="button"
                className="terminal-action danger"
                disabled={serverBusy}
                onClick={() => void toggleServer()}
              >
                Stop
              </button>
            </>
          ) : (
            <button
              type="button"
              className="terminal-action primary"
              disabled={serverBusy}
              onClick={() => void toggleServer()}
              title="Start static file server"
            >
              Serve
            </button>
          )}
          <button type="button" className="terminal-action" onClick={focusTerm}>
            Focus
          </button>
        </div>
      </div>
      <div
        className="terminal-xterm"
        ref={hostRef}
        tabIndex={0}
        onFocus={focusTerm}
        onClick={focusTerm}
      />
      {ctxMenu && (
        <div
          className="terminal-ctx"
          style={{ left: ctxMenu.x, top: ctxMenu.y }}
          onMouseDown={(e) => e.stopPropagation()}
        >
          <button type="button" disabled={!ctxMenu.canCopy} onClick={() => void copyFromMenu()}>
            Copy
            <kbd>Ctrl+C</kbd>
          </button>
          <button type="button" onClick={() => void pasteFromMenu()}>
            Paste
            <kbd>Ctrl+V</kbd>
          </button>
        </div>
      )}
    </div>
  )
}
