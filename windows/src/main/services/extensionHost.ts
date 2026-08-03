import * as fs from 'fs'
import * as path from 'path'
import { app, BrowserWindow } from 'electron'
import { createRequire } from 'module'
import { createVscodeApi, type ShimWebviewView } from './vscodeShim'
import { ensurePluginStaticServer, getPluginStaticPort } from './pluginStaticServer'

// IMPORTANT: do NOT `import * as Module from 'module'` — that namespace is getter-only
// in electron-vite ESM bundles ("Cannot set property _load ... which has only a getter").
const nodeRequire = createRequire(__filename)
const NodeModule = nodeRequire('module') as {
  _load: (request: string, parent: unknown, isMain: boolean) => unknown
  _resolveFilename: (request: string, parent: unknown, isMain: boolean, options?: unknown) => string
  prototype: { require: (id: string) => unknown }
  _initPaths?: () => void
  globalPaths: string[]
}

export type ExtensionHostStatus = 'idle' | 'starting' | 'running' | 'error'

export interface ExtensionHostHandle {
  pluginId: string
  status: ExtensionHostStatus
  error?: string
  viewType?: string
  /** The webview HTML as produced by resolveWebviewView — serves as host-mode page. */
  resolvedHtml?: string
  dispose: () => void
  postFromWebview: (message: unknown) => void
}

interface HostSession {
  handle: ExtensionHostHandle
  view?: ShimWebviewView
  restoreLoad?: () => void
  api?: ReturnType<typeof createVscodeApi>
}

const sessions = new Map<string, HostSession>()
const vscodeByPlugin = new Map<string, unknown>()

function storageRootFor(pluginId: string): string {
  return path.join(app.getPath('userData'), 'plugins', 'host-state', pluginId)
}

async function writeVscodeStub(storageRoot: string, globalKey: string): Promise<string> {
  const dir = path.join(storageRoot, 'host-modules', 'vscode')
  await fs.promises.mkdir(dir, { recursive: true })
  const indexPath = path.join(dir, 'index.js')
  // Try global, globalThis, and self — electron-vite bundled main may alias these differently
  await fs.promises.writeFile(
    indexPath,
    `'use strict'
var k = ${JSON.stringify(globalKey)};
var g = (typeof globalThis !== 'undefined' ? globalThis : typeof global !== 'undefined' ? global : typeof self !== 'undefined' ? self : this);
var m = g[k];
if (!m) { throw new Error('[lithe] vscode shim not found on globalThis[' + k + ']'); }
module.exports = m;
`,
    'utf8'
  )
  await fs.promises.writeFile(
    path.join(dir, 'package.json'),
    JSON.stringify({ name: 'vscode', version: '1.84.0', main: 'index.js' }, null, 2),
    'utf8'
  )
  return indexPath
}

/**
 * Inject `require('vscode')` for extension code.
 * Uses Module.prototype.require + optional physical stub resolution.
 */
function installVscodeHook(vscode: unknown, pluginId: string, stubPath?: string): () => void {
  vscodeByPlugin.set(pluginId, vscode)
  const restorers: Array<() => void> = []

  // 1) Prototype require — most reliable inside Electron bundled main
  try {
    const proto = NodeModule.prototype
    const originalRequire = proto.require
    proto.require = function (this: unknown, id: string) {
      if (id === 'vscode') {
        return vscodeByPlugin.get(pluginId) || [...vscodeByPlugin.values()].at(-1) || vscode
      }
      return originalRequire.apply(this, [id])
    }
    restorers.push(() => {
      proto.require = originalRequire
    })
  } catch (err) {
    console.warn('[ext-host] prototype.require hook failed', err)
  }

  // 2) Module._load when the real Module object is writable
  try {
    const desc = Object.getOwnPropertyDescriptor(NodeModule, '_load')
    if (desc?.writable || desc?.configurable) {
      const originalLoad = NodeModule._load
      NodeModule._load = function (request, parent, isMain) {
        if (request === 'vscode') return vscode
        return originalLoad.call(this, request, parent, isMain)
      }
      restorers.push(() => {
        NodeModule._load = originalLoad
      })
    }
  } catch (err) {
    console.warn('[ext-host] Module._load hook skipped', err)
  }

  // 3) Resolve filename to physical stub
  if (stubPath) {
    try {
      const originalResolve = NodeModule._resolveFilename
      NodeModule._resolveFilename = function (request, parent, isMain, options) {
        if (request === 'vscode') return stubPath
        return originalResolve.call(this, request, parent, isMain, options)
      }
      restorers.push(() => {
        NodeModule._resolveFilename = originalResolve
      })
    } catch (err) {
      console.warn('[ext-host] _resolveFilename hook skipped', err)
    }
  }

  return () => {
    vscodeByPlugin.delete(pluginId)
    for (const restore of restorers.reverse()) {
      try {
        restore()
      } catch {
        /* ignore */
      }
    }
  }
}

function broadcastToRenderers(pluginId: string, message: unknown): void {
  for (const win of BrowserWindow.getAllWindows()) {
    win.webContents.send('plugin:host-event', { pluginId, message })
  }
}

/** Extension Host → Lithe renderer UI actions (open editor, show diff, run in terminal). */
function sendLitheAction(pluginId: string, action: string, payload: unknown): void {
  for (const win of BrowserWindow.getAllWindows()) {
    win.webContents.send('plugin:lithe-action', { pluginId, action, payload })
  }
}

function findSidebarViewType(pkg: any): string | undefined {
  const views = pkg?.contributes?.views || {}
  for (const key of Object.keys(views)) {
    const arr = views[key]
    if (!Array.isArray(arr)) continue
    for (const v of arr) {
      if (v?.type === 'webview' && typeof v.id === 'string') return v.id
    }
  }
  return undefined
}

function readPackageJson(extensionPath: string): any {
  try {
    return JSON.parse(fs.readFileSync(path.join(extensionPath, 'package.json'), 'utf8'))
  } catch {
    return {}
  }
}

/** Start (or reuse) an in-process Extension Host for a VS Code plugin. */
export async function startExtensionHost(opts: {
  pluginId: string
  extensionPath: string
  cwd?: string
}): Promise<ExtensionHostHandle> {
  const existing = sessions.get(opts.pluginId)
  if (existing && existing.handle.status === 'running') {
    return existing.handle
  }
  if (existing) {
    existing.handle.dispose()
  }

  const handle: ExtensionHostHandle = {
    pluginId: opts.pluginId,
    status: 'starting',
    dispose: () => {},
    postFromWebview: () => {}
  }

  const session: HostSession = { handle }
  sessions.set(opts.pluginId, session)

  handle.dispose = () => {
    try {
      session.view?.webview.dispose()
    } catch {
      /* ignore */
    }
    session.restoreLoad?.()
    sessions.delete(opts.pluginId)
  }

  try {
    await ensurePluginStaticServer()
    const staticPort = getPluginStaticPort()
    const storageRoot = storageRootFor(opts.pluginId)
    await fs.promises.mkdir(storageRoot, { recursive: true })

    const api = createVscodeApi({
      extensionPath: opts.extensionPath,
      storageRoot,
      cwd: opts.cwd,
      pluginId: opts.pluginId,
      staticPort,
      onPostToWebview: (message) => broadcastToRenderers(opts.pluginId, message),
      onLitheAction: (action, payload) => sendLitheAction(opts.pluginId, action, payload),
      log: (line) => console.log(`[ext:${opts.pluginId}] ${line}`)
    })

    const globalKey = `__litheVscode_${opts.pluginId.replace(/[^a-zA-Z0-9_$]/g, '_')}`
    ;(globalThis as any)[globalKey] = api.vscode
    const stubPath = await writeVscodeStub(storageRoot, globalKey)

    session.restoreLoad = installVscodeHook(api.vscode, opts.pluginId, stubPath)
    session.api = api

    const pkg = readPackageJson(opts.extensionPath)
    const mainRel = String(pkg.main || './dist/extension.js')
    const mainPath = path.resolve(opts.extensionPath, mainRel)
    if (!fs.existsSync(mainPath)) {
      throw new Error(`Extension entry not found: ${mainPath}`)
    }

    // Clear require cache so re-enable reloads
    try {
      const resolved = nodeRequire.resolve(mainPath)
      delete nodeRequire.cache[resolved]
    } catch {
      try {
        delete require.cache[require.resolve(mainPath)]
      } catch {
        /* ignore */
      }
    }

    const ext = nodeRequire(mainPath) as {
      activate?: (ctx: unknown) => unknown
      deactivate?: () => unknown
    }
    if (typeof ext.activate !== 'function') {
      throw new Error('Extension does not export activate()')
    }

    await Promise.race([
      Promise.resolve(ext.activate(api.context)),
      new Promise((_resolve, reject) => {
        setTimeout(() => reject(new Error('activate() timed out after 45s')), 45_000)
      })
    ])

    const registered = api.getRegisteredViewTypes()
    console.log(`[ext:${opts.pluginId}] providers:`, registered)

    const viewType = findSidebarViewType(pkg)
    let provider = viewType ? api.getRegisteredProvider(viewType) : undefined
    if (!provider) {
      provider =
        api.getRegisteredProvider('kilo-code.SidebarProvider') ||
        api.getRegisteredProvider(`${opts.pluginId}.SidebarProvider`)
    }

    if (!provider && pkg?.contributes?.views) {
      for (const arr of Object.values(pkg.contributes.views) as any[]) {
        if (!Array.isArray(arr)) continue
        for (const v of arr) {
          if (v?.id) {
            provider = api.getRegisteredProvider(String(v.id))
            if (provider) {
              handle.viewType = String(v.id)
              break
            }
          }
        }
        if (provider) break
      }
    }

    if (!provider && registered.length) {
      handle.viewType = registered[0]
      provider = api.getRegisteredProvider(registered[0])
    }

    if (!provider) {
      throw new Error(
        'Extension activated but no WebviewViewProvider was registered. Mock UI state will still be used.'
      )
    }

    const resolvedType = handle.viewType || viewType || registered[0] || 'sidebar'
    handle.viewType = resolvedType
    const view = api.createWebviewView(resolvedType)
    session.view = view

    const token = {
      isCancellationRequested: false,
      onCancellationRequested: () => ({ dispose: () => {} })
    }
    await Promise.resolve(provider.resolveWebviewView(view, {}, token as any))
    handle.resolvedHtml = view.webview.html || ''

    handle.postFromWebview = (message: unknown) => {
      view.webview.receiveFromIframe(message)
    }

    handle.status = 'running'
    console.log(`[ext:${opts.pluginId}] Extension Host running (${resolvedType})`)
    return handle
  } catch (err: any) {
    handle.status = 'error'
    handle.error = err?.message || String(err)
    console.error(`[ext:${opts.pluginId}] Extension Host failed:`, handle.error)
    return handle
  }
}

export function getExtensionHost(pluginId: string): ExtensionHostHandle | undefined {
  return sessions.get(pluginId)?.handle
}

export function postToExtensionHost(pluginId: string, message: unknown): boolean {
  const session = sessions.get(pluginId)
  if (!session || session.handle.status !== 'running') return false
  session.handle.postFromWebview(message)
  return true
}

/** Execute a command the plugin registered via vscode.commands.registerCommand. */
export async function executeExtensionCommand(
  pluginId: string,
  commandId: string,
  ...args: unknown[]
): Promise<{ ok: boolean; error?: string }> {
  const session = sessions.get(pluginId)
  if (!session || session.handle.status !== 'running' || !session.api) {
    return { ok: false, error: 'Extension host not running' }
  }
  if (!session.api.hasCommand(commandId)) {
    return { ok: false, error: `Command not registered: ${commandId}` }
  }
  try {
    await Promise.resolve(session.api.executeCommand(commandId, ...args))
    return { ok: true }
  } catch (err: any) {
    return { ok: false, error: err?.message || String(err) }
  }
}

export function disposeExtensionHost(pluginId: string): void {
  sessions.get(pluginId)?.handle.dispose()
}
