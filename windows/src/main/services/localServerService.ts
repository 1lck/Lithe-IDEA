import { ipcMain, shell } from 'electron'
import * as http from 'http'
import * as fs from 'fs'
import * as fsp from 'fs/promises'
import * as path from 'path'
import { IPC } from '@common/ipc'

interface ServerState {
  server: http.Server
  root: string
  port: number
  url: string
}

const MIME: Record<string, string> = {
  '.html': 'text/html; charset=utf-8',
  '.htm': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
  '.ico': 'image/x-icon',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.ttf': 'font/ttf',
  '.txt': 'text/plain; charset=utf-8',
  '.md': 'text/markdown; charset=utf-8',
  '.map': 'application/json',
  '.wasm': 'application/wasm'
}

let state: ServerState | null = null

function contentType(filePath: string): string {
  return MIME[path.extname(filePath).toLowerCase()] || 'application/octet-stream'
}

async function tryFile(filePath: string): Promise<Buffer | null> {
  try {
    const st = await fsp.stat(filePath)
    if (!st.isFile()) return null
    return await fsp.readFile(filePath)
  } catch {
    return null
  }
}

function makeHandler(root: string) {
  return async (req: http.IncomingMessage, res: http.ServerResponse): Promise<void> => {
    try {
      const rawUrl = req.url || '/'
      const urlPath = decodeURIComponent(rawUrl.split('?')[0])
      let rel = urlPath.replace(/^\/+/, '')
      if (rel.includes('..')) {
        res.writeHead(403)
        res.end('Forbidden')
        return
      }

      let target = path.join(root, rel || '.')
      let body = await tryFile(target)

      if (!body) {
        const asIndex = path.join(target, 'index.html')
        body = await tryFile(asIndex)
        if (body) target = asIndex
      }

      if (!body && (rel === '' || rel.endsWith('/'))) {
        // Simple directory listing
        try {
          const dir = path.join(root, rel)
          const names = await fsp.readdir(dir)
          const links = names
            .map((n) => `<li><a href="${path.posix.join('/', rel, n)}">${n}</a></li>`)
            .join('\n')
          const html = `<!doctype html><html><head><meta charset="utf-8"><title>${rel || '/'}</title>
<style>body{font:14px/1.5 system-ui;padding:24px;background:#13151a;color:#e0e4ec}
a{color:#4f94fa;text-decoration:none}a:hover{text-decoration:underline}li{margin:4px 0}</style>
</head><body><h1>Index of /${rel}</h1><ul>${links}</ul></body></html>`
          res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' })
          res.end(html)
          return
        } catch {
          /* fallthrough */
        }
      }

      if (!body) {
        res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' })
        res.end('404 Not Found')
        return
      }

      res.writeHead(200, {
        'Content-Type': contentType(target),
        'Cache-Control': 'no-cache'
      })
      res.end(body)
    } catch (err: any) {
      res.writeHead(500)
      res.end(String(err?.message || err))
    }
  }
}

function listen(server: http.Server, port: number): Promise<number> {
  return new Promise((resolve, reject) => {
    const onError = (err: NodeJS.ErrnoException): void => {
      server.off('listening', onListening)
      reject(err)
    }
    const onListening = (): void => {
      server.off('error', onError)
      const addr = server.address()
      resolve(typeof addr === 'object' && addr ? addr.port : port)
    }
    server.once('error', onError)
    server.once('listening', onListening)
    server.listen(port, '127.0.0.1')
  })
}

export function registerLocalServerHandlers(): void {
  ipcMain.handle(IPC.LOCAL_SERVER_START, async (_e, root: string, preferredPort = 5500) => {
    if (!root || !fs.existsSync(root)) throw new Error('Invalid project root')

    const want = Math.min(65535, Math.max(1, Number(preferredPort) || 5500))

    // Restart if already running on a different port/root
    if (state) {
      if (state.port === want && state.root === root) {
        return { url: state.url, port: state.port, root: state.root, already: true }
      }
      const prev = state
      state = null
      await new Promise<void>((resolve) => prev.server.close(() => resolve()))
    }

    let port = want
    let server = http.createServer(makeHandler(root))
    try {
      port = await listen(server, want)
    } catch (err: any) {
      server.close()
      if (err?.code === 'EADDRINUSE') {
        throw new Error(`Port ${want} is already in use`)
      }
      throw err
    }

    const url = `http://127.0.0.1:${port}/`
    state = { server, root, port, url }
    return { url, port, root, already: false }
  })

  ipcMain.handle(IPC.LOCAL_SERVER_STOP, async () => {
    if (!state) return { stopped: false }
    const s = state
    state = null
    await new Promise<void>((resolve) => s.server.close(() => resolve()))
    return { stopped: true }
  })

  ipcMain.handle(IPC.LOCAL_SERVER_STATUS, async () => {
    if (!state) return { running: false }
    return { running: true, url: state.url, port: state.port, root: state.root }
  })

  ipcMain.handle(IPC.LOCAL_SERVER_OPEN, async () => {
    if (!state) throw new Error('Server not running')
    await shell.openExternal(state.url)
    return { url: state.url }
  })
}

export function stopLocalServerOnQuit(): void {
  if (state) {
    try { state.server.close() } catch { /* ignore */ }
    state = null
  }
}
