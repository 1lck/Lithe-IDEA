import { ipcMain, BrowserWindow } from 'electron'
import { IPC } from '@common/ipc'
import * as fs from 'fs'
import * as path from 'path'
import type { IPty } from 'node-pty'

// Use require so electron-vite keeps the native module external
// eslint-disable-next-line @typescript-eslint/no-var-requires
const pty = require('node-pty') as typeof import('node-pty')

interface TerminalSession {
  pty: IPty
  cwd: string
  senderId: number
}

const terminals = new Map<string, TerminalSession>()

function send(senderId: number, channel: string, payload: unknown): void {
  for (const win of BrowserWindow.getAllWindows()) {
    if (win.webContents.id === senderId && !win.isDestroyed()) {
      win.webContents.send(channel, payload)
    }
  }
}

function resolveShell(shell?: string): { file: string; args: string[] } {
  const kind = (shell || 'system').toLowerCase()

  if (kind === 'cmd') {
    return {
      file: process.env.COMSPEC || 'C:\\Windows\\System32\\cmd.exe',
      args: []
    }
  }

  if (kind === 'gitbash') {
    const candidates = [
      'C:\\Program Files\\Git\\bin\\bash.exe',
      'C:\\Program Files (x86)\\Git\\bin\\bash.exe'
    ]
    for (const c of candidates) {
      if (fs.existsSync(c)) return { file: c, args: ['--login', '-i'] }
    }
  }

  // Prefer PowerShell 7, then Windows PowerShell
  const pwsh = [
    process.env.LITHE_POWERSHELL,
    path.join(process.env.ProgramFiles || 'C:\\Program Files', 'PowerShell', '7', 'pwsh.exe'),
    'C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe'
  ].filter(Boolean) as string[]

  for (const file of pwsh) {
    if (fs.existsSync(file)) {
      return { file, args: ['-NoLogo'] }
    }
  }

  return {
    file: 'C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe',
    args: ['-NoLogo']
  }
}

export function registerTerminalHandlers(): void {
  ipcMain.handle(
    IPC.TERMINAL_CREATE,
    async (event, id: string, cwd: string, shell?: string, cols = 80, rows = 24) => {
      const existing = terminals.get(id)
      if (existing) {
        try { existing.pty.kill() } catch { /* ignore */ }
        terminals.delete(id)
      }

      const workdir = cwd && fs.existsSync(cwd) ? cwd : process.env.USERPROFILE || process.cwd()
      const { file, args } = resolveShell(shell)
      const senderId = event.sender.id

      const env: Record<string, string> = {}
      for (const [k, v] of Object.entries(process.env)) {
        if (typeof v === 'string') env[k] = v
      }
      // Interactive TTY: enable color, clear any disable flags inherited from Electron/CI
      delete env.NO_COLOR
      delete env.NODE_DISABLE_COLORS
      delete env.CLI_NO_COLOR
      env.TERM = 'xterm-256color'
      env.COLORTERM = 'truecolor'
      env.FORCE_COLOR = '1'

      let proc: IPty
      try {
        proc = pty.spawn(file, args, {
          name: 'xterm-256color',
          cols: Math.max(cols, 40),
          rows: Math.max(rows, 12),
          cwd: workdir,
          env,
          useConpty: true,
          useConptyDll: true
        })
      } catch {
        proc = pty.spawn(file, args, {
          name: 'xterm-256color',
          cols: Math.max(cols, 40),
          rows: Math.max(rows, 12),
          cwd: workdir,
          env,
          useConpty: true
        })
      }

      terminals.set(id, { pty: proc, cwd: workdir, senderId })

      proc.onData((data) => {
        send(senderId, IPC.TERMINAL_DATA, { id, data })
      })

      proc.onExit(({ exitCode }) => {
        send(senderId, IPC.TERMINAL_DATA, {
          id,
          data: `\r\n\x1b[90m[Process exited with code ${exitCode}]\x1b[0m\r\n`
        })
        send(senderId, IPC.TERMINAL_EXIT, { id, code: exitCode })
        terminals.delete(id)
      })

      return { cwd: workdir, shell: file, interactive: true }
    }
  )

  ipcMain.handle(IPC.TERMINAL_WRITE, async (_e, id: string, data: string) => {
    const session = terminals.get(id)
    if (!session) {
      throw new Error(`Terminal session not found: ${id}`)
    }
    try {
      session.pty.write(data)
    } catch (err: any) {
      throw new Error(err?.message || 'Failed to write to PTY')
    }
  })

  ipcMain.handle(IPC.TERMINAL_RESIZE, async (_e, id: string, cols: number, rows: number) => {
    const session = terminals.get(id)
    if (!session) return
    try {
      session.pty.resize(Math.max(cols, 2), Math.max(rows, 2))
    } catch {
      /* ignore */
    }
  })

  ipcMain.handle(IPC.TERMINAL_DESTROY, async (_e, id: string) => {
    const session = terminals.get(id)
    if (!session) return
    try { session.pty.kill() } catch { /* ignore */ }
    terminals.delete(id)
  })

  // Kept for compatibility with older renderer calls
  ipcMain.handle(IPC.TERMINAL_EXEC, async (_e, id: string, command: string) => {
    const session = terminals.get(id)
    if (!session) return
    session.pty.write(command + '\r')
  })

  ipcMain.handle(IPC.TERMINAL_INTERRUPT, async (_e, id: string) => {
    const session = terminals.get(id)
    if (!session) return
    session.pty.write('\x03')
  })

  ipcMain.handle(IPC.TERMINAL_CWD, async (_e, id: string) => {
    return terminals.get(id)?.cwd || process.cwd()
  })

  ipcMain.handle(IPC.TERMINAL_CD, async (_e, id: string, target: string) => {
    const session = terminals.get(id)
    if (!session) throw new Error('Terminal not found')
    session.pty.write(`cd "${target.replace(/"/g, '`"')}"\r`)
    return { cwd: session.cwd }
  })

  ipcMain.handle(IPC.TERMINAL_COMPLETE, async () => {
    // Real PTY uses shell-native Tab completion
    return { replacements: [], replaceFrom: 0 }
  })
}
