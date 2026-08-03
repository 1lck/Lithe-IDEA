/**
 * Minimal VS Code API surface for running packaged extensions inside Lithe.
 * Not complete — stubs avoid throws; enough for Cline/Kilo-style activate + webview.
 */
import { EventEmitter } from 'events'
import * as fs from 'fs'
import * as path from 'path'
import * as os from 'os'
import { createHash, randomUUID } from 'crypto'

export type Disposable = { dispose: () => void }

export function toDisposable(fn: () => void): Disposable {
  return { dispose: fn }
}

/**
 * Locate a directory that Kilo/Cline-style extensions can treat as VS Code's
 * `appRoot` — meaning it contains `node_modules/@vscode/ripgrep/bin/rg[.exe]`.
 * Without this, workspace file search / `@file` mentions / ripgrep-based
 * grep tools all fail with "Could not find ripgrep binary".
 */
export function resolveAppRoot(storageRoot: string, log: (s: string) => void): string {
  const rgName = process.platform === 'win32' ? 'rg.exe' : 'rg'
  const rgRelPaths = [
    path.join('node_modules', '@vscode', 'ripgrep', 'bin', rgName),
    path.join('node_modules', 'vscode-ripgrep', 'bin', rgName),
    path.join('node_modules.asar.unpacked', '@vscode', 'ripgrep', 'bin', rgName),
    path.join('node_modules.asar.unpacked', 'vscode-ripgrep', 'bin', rgName)
  ]
  const hasRg = (root: string): boolean => rgRelPaths.some((r) => fs.existsSync(path.join(root, r)))

  const tried: string[] = []
  const candidates: string[] = []

  // 1) Electron app root (dev + packaged)
  try {
    const { app } = require('electron') as typeof import('electron')
    if (app?.getAppPath) candidates.push(app.getAppPath())
  } catch {
    /* not running under Electron (harness/tests) */
  }

  // 2) process.cwd() and parents up to filesystem root — covers pnpm workspace layouts
  let cwd = process.cwd()
  for (let i = 0; i < 6; i++) {
    candidates.push(cwd)
    const parent = path.dirname(cwd)
    if (parent === cwd) break
    cwd = parent
  }

  // 3) __dirname walking — main-process bundle may live under out/main
  let d = __dirname
  for (let i = 0; i < 6; i++) {
    candidates.push(d)
    const parent = path.dirname(d)
    if (parent === d) break
    d = parent
  }

  for (const root of candidates) {
    if (!root || tried.includes(root)) continue
    tried.push(root)
    if (hasRg(root)) {
      log(`[host] appRoot resolved: ${root}`)
      return root
    }
  }

  // 4) Last resort — synthesize an appRoot in the plugin's storage that
  //    contains a symlink/junction to the ripgrep package we found on PATH.
  try {
    const { execSync } = require('child_process') as typeof import('child_process')
    const which = process.platform === 'win32'
      ? execSync('where rg 2>NUL', { stdio: ['ignore', 'pipe', 'ignore'] }).toString().split(/\r?\n/)[0]?.trim()
      : execSync('which rg 2>/dev/null', { stdio: ['ignore', 'pipe', 'ignore'] }).toString().trim()
    if (which && fs.existsSync(which)) {
      const fakeRoot = path.join(storageRoot, 'appRoot')
      const binDir = path.join(fakeRoot, 'node_modules', '@vscode', 'ripgrep', 'bin')
      fs.mkdirSync(binDir, { recursive: true })
      const target = path.join(binDir, rgName)
      if (!fs.existsSync(target)) fs.copyFileSync(which, target)
      // Minimal package.json so `require.resolve('@vscode/ripgrep/package.json')` works.
      const pkgDir = path.join(fakeRoot, 'node_modules', '@vscode', 'ripgrep')
      const pkgPath = path.join(pkgDir, 'package.json')
      if (!fs.existsSync(pkgPath)) {
        fs.writeFileSync(
          pkgPath,
          JSON.stringify({ name: '@vscode/ripgrep', version: '0.0.0-lithe', main: 'lib/index.js' }),
          'utf8'
        )
      }
      log(`[host] appRoot synthesized: ${fakeRoot} (rg from ${which})`)
      return fakeRoot
    }
  } catch {
    /* ignore */
  }

  log(`[host] WARNING: ripgrep not found. workspace search & @file mentions will fail. Tried: ${tried.join(' | ')}`)
  return tried[0] || process.cwd()
}

export class Emitter<T> {
  private emitter = new EventEmitter()
  event = (listener: (e: T) => unknown, _thisArgs?: unknown, disposables?: Disposable[]): Disposable => {
    const bound = (e: T): void => {
      listener(e)
    }
    this.emitter.on('e', bound)
    const d = toDisposable(() => this.emitter.off('e', bound))
    disposables?.push(d)
    return d
  }
  fire(data: T): void {
    this.emitter.emit('e', data)
  }
  dispose(): void {
    this.emitter.removeAllListeners()
  }
}

export class Uri {
  readonly scheme: string
  readonly authority: string
  readonly path: string
  readonly query: string
  readonly fragment: string

  constructor(scheme: string, authority: string, pathName: string, query = '', fragment = '') {
    this.scheme = scheme
    this.authority = authority
    this.path = pathName
    this.query = query
    this.fragment = fragment
  }

  get fsPath(): string {
    if (process.platform === 'win32' && this.path.startsWith('/')) {
      // /C:/foo → C:\foo
      const m = this.path.match(/^\/([A-Za-z]:)(.*)$/)
      if (m) return path.normalize(m[1] + m[2].replace(/\//g, '\\'))
    }
    return path.normalize(this.path.replace(/\//g, path.sep))
  }

  static file(filePath: string): Uri {
    let p = path.resolve(filePath).replace(/\\/g, '/')
    if (process.platform === 'win32' && !p.startsWith('/')) p = '/' + p
    return new Uri('file', '', p)
  }

  static parse(value: string): Uri {
    try {
      const u = new URL(value)
      return new Uri(u.protocol.replace(':', ''), u.host, decodeURIComponent(u.pathname), u.search.replace(/^\?/, ''), u.hash.replace(/^#/, ''))
    } catch {
      return Uri.file(value)
    }
  }

  static joinPath(base: Uri, ...pathFragments: string[]): Uri {
    const joined = path.posix.join(base.path.replace(/\\/g, '/'), ...pathFragments.map((p) => p.replace(/\\/g, '/')))
    return new Uri(base.scheme, base.authority, joined, base.query, base.fragment)
  }

  static from(components: { scheme: string; authority?: string; path?: string; query?: string; fragment?: string }): Uri {
    return new Uri(components.scheme, components.authority || '', components.path || '', components.query || '', components.fragment || '')
  }

  with(change: { scheme?: string; authority?: string; path?: string; query?: string; fragment?: string }): Uri {
    return new Uri(
      change.scheme ?? this.scheme,
      change.authority ?? this.authority,
      change.path ?? this.path,
      change.query ?? this.query,
      change.fragment ?? this.fragment
    )
  }

  toString(_skipEncoding?: boolean): string {
    const auth = this.authority ? '//' + this.authority : this.scheme === 'file' ? '//' : ''
    const q = this.query ? '?' + this.query : ''
    const f = this.fragment ? '#' + this.fragment : ''
    return `${this.scheme}:${auth}${this.path}${q}${f}`
  }

  toJSON(): unknown {
    return { $mid: 1, scheme: this.scheme, authority: this.authority, path: this.path, query: this.query, fragment: this.fragment }
  }
}

class MementoImpl {
  constructor(
    private filePath: string,
    private data: Record<string, unknown>
  ) {}

  get<T>(key: string, defaultValue?: T): T | undefined {
    return (Object.prototype.hasOwnProperty.call(this.data, key) ? this.data[key] : defaultValue) as T | undefined
  }

  keys(): readonly string[] {
    return Object.keys(this.data)
  }

  setKeysForSync(_keys: readonly string[]): void {
    // No-op: Lithe does not sync extension state across machines.
  }

  async update(key: string, value: unknown): Promise<void> {
    if (value === undefined) delete this.data[key]
    else this.data[key] = value
    await fs.promises.mkdir(path.dirname(this.filePath), { recursive: true })
    await fs.promises.writeFile(this.filePath, JSON.stringify(this.data, null, 2), 'utf8')
  }
}

class SecretStorageImpl {
  private data = new Map<string, string>()
  private _onDidChange = new Emitter<{ key: string }>()
  onDidChange = this._onDidChange.event

  get(key: string): Promise<string | undefined> {
    return Promise.resolve(this.data.get(key))
  }
  store(key: string, value: string): Promise<void> {
    this.data.set(key, value)
    this._onDidChange.fire({ key })
    return Promise.resolve()
  }
  delete(key: string): Promise<void> {
    this.data.delete(key)
    this._onDidChange.fire({ key })
    return Promise.resolve()
  }
}

export type WebviewMessageListener = (message: unknown) => unknown

export class ShimWebview {
  html = ''
  options: { enableScripts?: boolean; localResourceRoots?: Uri[] } = { enableScripts: true }
  cspSource: string
  private listeners: WebviewMessageListener[] = []
  private _onDidDispose = new Emitter<void>()
  onDidDispose = this._onDidDispose.event

  constructor(
    private extensionRoot: string,
    private toHttpUrl: (absPath: string) => string,
    cspSource: string,
    private outbound: (msg: unknown) => void
  ) {
    this.cspSource = cspSource
  }

  asWebviewUri(localResource: Uri): Uri {
    const abs = localResource.fsPath
    const http = this.toHttpUrl(abs)
    return Uri.parse(http)
  }

  postMessage(message: unknown): Promise<boolean> {
    try {
      this.outbound(message)
      return Promise.resolve(true)
    } catch {
      return Promise.resolve(false)
    }
  }

  onDidReceiveMessage(listener: WebviewMessageListener, _thisArgs?: unknown, disposables?: Disposable[]): Disposable {
    this.listeners.push(listener)
    const d = toDisposable(() => {
      this.listeners = this.listeners.filter((l) => l !== listener)
    })
    disposables?.push(d)
    return d
  }

  /** Inject a message from the Lithe iframe into the extension. */
  receiveFromIframe(message: unknown): void {
    for (const l of [...this.listeners]) {
      try {
        void l(message)
      } catch (err) {
        console.error('[lithe-host] webview message handler error', err)
      }
    }
  }

  dispose(): void {
    this._onDidDispose.fire()
    this.listeners = []
  }
}

export class ShimWebviewView {
  webview: ShimWebview
  visible = true
  title = ''
  description = ''
  private _onDidChangeVisibility = new Emitter<void>()
  onDidChangeVisibility = this._onDidChangeVisibility.event
  private _onDidDispose = new Emitter<void>()
  onDidDispose = this._onDidDispose.event

  constructor(webview: ShimWebview, public readonly viewType: string) {
    this.webview = webview
  }

  show(_preserveFocus?: boolean): void {
    this.visible = true
    this._onDidChangeVisibility.fire()
  }
}

type WebviewViewProvider = {
  resolveWebviewView: (
    webviewView: ShimWebviewView,
    context: { state?: unknown },
    token: { isCancellationRequested: boolean; onCancellationRequested: Emitter<void>['event'] }
  ) => void | Promise<void>
}

export interface ShimOptions {
  extensionPath: string
  storageRoot: string
  cwd?: string
  pluginId: string
  staticPort: number
  onPostToWebview: (message: unknown) => void
  /** Dispatch a UI request to Lithe's renderer (open file, show diff, run in terminal). */
  onLitheAction?: (action: string, payload: unknown) => void
  log?: (line: string) => void
}

export function createVscodeApi(opts: ShimOptions): {
  vscode: any
  context: any
  getRegisteredProvider: (viewType: string) => WebviewViewProvider | undefined
  getRegisteredViewTypes: () => string[]
  createWebviewView: (viewType: string) => ShimWebviewView
  executeCommand: (id: string, ...args: unknown[]) => unknown
  hasCommand: (id: string) => boolean
} {
  const log = opts.log || ((s: string) => console.log(s))
  const providers = new Map<string, WebviewViewProvider>()
  const commandMap = new Map<string, (...args: unknown[]) => unknown>()
  const extensionUri = Uri.file(opts.extensionPath)
  const globalStatePath = path.join(opts.storageRoot, 'global-state.json')
  const workspaceStatePath = path.join(opts.storageRoot, 'workspace-state.json')

  const readJson = (p: string): Record<string, unknown> => {
    try {
      return JSON.parse(fs.readFileSync(p, 'utf8'))
    } catch {
      return {}
    }
  }

  const globalState = new MementoImpl(globalStatePath, readJson(globalStatePath))
  const workspaceState = new MementoImpl(workspaceStatePath, readJson(workspaceStatePath))
  const secrets = new SecretStorageImpl()

  // Persistent workspace configuration (vscode.workspace.getConfiguration)
  const configPath = path.join(opts.storageRoot, 'workspace-config.json')
  const configStore: Record<string, unknown> = readJson(configPath)
  let configWriteTimer: NodeJS.Timeout | null = null
  const persistConfig = async (): Promise<void> => {
    if (configWriteTimer) clearTimeout(configWriteTimer)
    await new Promise<void>((resolve) => {
      configWriteTimer = setTimeout(() => {
        fs.promises
          .mkdir(path.dirname(configPath), { recursive: true })
          .then(() => fs.promises.writeFile(configPath, JSON.stringify(configStore, null, 2), 'utf8'))
          .catch(() => {})
          .finally(() => resolve())
      }, 80)
    })
  }
  const onDidChangeConfiguration = new Emitter<unknown>()

  const toHttpUrl = (absPath: string): string => {
    const root = path.resolve(opts.extensionPath)
    const abs = path.resolve(absPath)
    let rel = path.relative(root, abs).replace(/\\/g, '/')
    if (rel.startsWith('..')) {
      // Outside extension — still try to serve via absolute encoding fallback
      rel = abs.replace(/\\/g, '/')
      return `http://127.0.0.1:${opts.staticPort}/p/${encodeURIComponent(opts.pluginId)}/${rel.split('/').map(encodeURIComponent).join('/')}`
    }
    return `http://127.0.0.1:${opts.staticPort}/p/${encodeURIComponent(opts.pluginId)}/${rel.split('/').map(encodeURIComponent).join('/')}`
  }

  const cspSource = `http://127.0.0.1:${opts.staticPort}`

  const outputChannels: Array<{ appendLine: (s: string) => void }> = []

  const workspaceFolders = opts.cwd
    ? [{ uri: Uri.file(opts.cwd), name: path.basename(opts.cwd), index: 0 }]
    : []

  /** Auto-stub unknown APIs so activate() doesn't die on the next missing method. */
  const stubMissing = <T extends object>(target: T, label: string): T =>
    new Proxy(target, {
      get(obj, prop, receiver) {
        if (prop in obj || typeof prop === 'symbol') {
          return Reflect.get(obj, prop, receiver)
        }
        const name = String(prop)
        if (name.startsWith('onDid')) {
          const ev = new Emitter<unknown>().event
          ;(obj as any)[prop] = ev
          return ev
        }
        const stub = (..._args: unknown[]) => {
          log(`[host] stub ${label}.${name}()`)
          return toDisposable(() => {})
        }
        ;(obj as any)[prop] = stub
        return stub
      }
    })

  const vscode = {
    version: '1.84.0',
    Uri,
    Disposable: { from: (...ds: Disposable[]) => toDisposable(() => ds.forEach((d) => d.dispose())) },
    EventEmitter: Emitter,
    CancellationTokenSource: class {
      token = {
        isCancellationRequested: false,
        onCancellationRequested: new Emitter<void>().event
      }
      cancel(): void {
        this.token.isCancellationRequested = true
      }
      dispose(): void {}
    },
    ThemeIcon: class {
      constructor(public id: string, public color?: unknown) {}
    },
    ThemeColor: class {
      constructor(public id: string) {}
    },
    RelativePattern: class {
      constructor(
        public base: string | Uri,
        public pattern: string
      ) {}
    },
    FileType: { Unknown: 0, File: 1, Directory: 2, SymbolicLink: 64 },
    FilePermission: { Readonly: 1 },
    TabInputText: class {
      constructor(public uri: Uri) {}
    },
    TabInputTextDiff: class {
      constructor(public original: Uri, public modified: Uri) {}
    },
    TabInputWebview: class {
      constructor(public viewType: string) {}
    },
    OverviewRulerLane: { Left: 1, Center: 2, Right: 4, Full: 7 },
    Decoration: {
      Insert: 1,
      Delete: 2,
      Modify: 4
    },
    StatusBarAlignment: { Left: 1, Right: 2 },
    ViewColumn: { Active: -1, Beside: -2, One: 1, Two: 2, Three: 3 },
    ConfigurationTarget: { Global: 1, Workspace: 2, WorkspaceFolder: 3 },
    ProgressLocation: { Notification: 15, Window: 10, SourceControl: 1 },
    UIKind: { Desktop: 1, Web: 2 },
    ExtensionMode: { Production: 1, Development: 2, Test: 3 },
    ExtensionKind: { UI: 1, Workspace: 2 },
    TreeItemCollapsibleState: { None: 0, Collapsed: 1, Expanded: 2 },
    DiagnosticSeverity: { Error: 0, Warning: 1, Information: 2, Hint: 3 },
    TextEditorRevealType: { Default: 0, InCenter: 1, InCenterIfOutsideViewport: 2, AtTop: 3 },
    TextEditorSelectionChangeKind: { Keyboard: 1, Mouse: 2, Command: 3 },
    EndOfLine: { LF: 1, CRLF: 2 },
    Position: class {
      constructor(public line: number, public character: number) {}
    },
    Range: class {
      constructor(public start: any, public end: any) {}
    },
    Selection: class {
      constructor(public anchor: any, public active: any) {}
    },
    Location: class {
      constructor(public uri: Uri, public rangeOrPosition: unknown) {}
    },
    MarkdownString: class {
      value: string
      isTrusted: boolean | { readonly enabledCommands: readonly string[] } = false
      supportThemeIcons = false
      supportHtml = false
      baseUri: Uri | undefined
      constructor(value = '', supportThemeIcons = false) {
        this.value = value
        this.supportThemeIcons = supportThemeIcons
      }
      appendText(value: string): this {
        this.value += value.replace(/[\\`*_{}[\]()#+\-.!]/g, '\\$&')
        return this
      }
      appendMarkdown(value: string): this {
        this.value += value
        return this
      }
      appendCodeblock(value: string, language = ''): this {
        this.value += `\n\`\`\`${language}\n${value}\n\`\`\`\n`
        return this
      }
    },
    SnippetString: class {
      value: string
      constructor(value = '') { this.value = value }
      appendText(v: string): this { this.value += v.replace(/\$/g, '\\$'); return this }
      appendTabstop(n = 0): this { this.value += `$${n}`; return this }
      appendPlaceholder(v: string, n = 0): this { this.value += `\${${n}:${v}}`; return this }
      appendChoice(vs: string[], n = 0): this { this.value += `\${${n}|${vs.join(',')}|}`; return this }
      appendVariable(name: string, def = ''): this { this.value += `\${${name}:${def}}`; return this }
    },
    TextEdit: class {
      constructor(public range: unknown, public newText: string) {}
      static replace(range: unknown, newText: string): unknown { return { range, newText } }
      static insert(position: unknown, newText: string): unknown { return { range: position, newText } }
      static delete(range: unknown): unknown { return { range, newText: '' } }
      static setEndOfLine(_eol: number): unknown { return { newEol: _eol } }
    },
    WorkspaceEdit: class {
      private edits: Array<[Uri, unknown]> = []
      replace(uri: Uri, range: unknown, newText: string): void { this.edits.push([uri, { range, newText }]) }
      insert(uri: Uri, position: unknown, newText: string): void { this.edits.push([uri, { range: position, newText }]) }
      delete(uri: Uri, range: unknown): void { this.edits.push([uri, { range, newText: '' }]) }
      has(uri: Uri): boolean { return this.edits.some(([u]) => u.fsPath === uri.fsPath) }
      set(uri: Uri, edits: unknown[]): void { for (const e of edits) this.edits.push([uri, e]) }
      get(uri: Uri): unknown[] { return this.edits.filter(([u]) => u.fsPath === uri.fsPath).map(([, e]) => e) }
      entries(): Array<[Uri, unknown[]]> {
        const map = new Map<string, [Uri, unknown[]]>()
        for (const [u, e] of this.edits) {
          const k = u.fsPath
          if (!map.has(k)) map.set(k, [u, []])
          map.get(k)![1].push(e)
        }
        return [...map.values()]
      }
      get size(): number { return this.entries().length }
    },
    Hover: class {
      constructor(public contents: unknown, public range?: unknown) {}
    },
    CompletionItem: class {
      label: string | { label: string }
      kind?: number
      detail?: string
      documentation?: unknown
      sortText?: string
      filterText?: string
      insertText?: string | unknown
      range?: unknown
      constructor(label: string | { label: string }, kind?: number) {
        this.label = label
        this.kind = kind
      }
    },
    CompletionList: class {
      constructor(public items: unknown[] = [], public isIncomplete = false) {}
    },
    CompletionItemKind: {
      Text: 0, Method: 1, Function: 2, Constructor: 3, Field: 4, Variable: 5, Class: 6, Interface: 7,
      Module: 8, Property: 9, Unit: 10, Value: 11, Enum: 12, Keyword: 13, Snippet: 14, Color: 15,
      File: 16, Reference: 17, Folder: 18, EnumMember: 19, Constant: 20, Struct: 21, Event: 22,
      Operator: 23, TypeParameter: 24, User: 25, Issue: 26
    },
    CompletionTriggerKind: { Invoke: 0, TriggerCharacter: 1, TriggerForIncompleteCompletions: 2 },
    SymbolKind: {
      File: 0, Module: 1, Namespace: 2, Package: 3, Class: 4, Method: 5, Property: 6, Field: 7,
      Constructor: 8, Enum: 9, Interface: 10, Function: 11, Variable: 12, Constant: 13, String: 14,
      Number: 15, Boolean: 16, Array: 17, Object: 18, Key: 19, Null: 20, EnumMember: 21, Struct: 22,
      Event: 23, Operator: 24, TypeParameter: 25
    },
    SymbolInformation: class {
      constructor(public name: string, public kind: number, public containerName: string, public location: unknown) {}
    },
    DocumentSymbol: class {
      children: unknown[] = []
      constructor(
        public name: string,
        public detail: string,
        public kind: number,
        public range: unknown,
        public selectionRange: unknown
      ) {}
    },
    Diagnostic: class {
      source?: string
      code?: string | number
      relatedInformation?: unknown[]
      tags?: number[]
      constructor(public range: unknown, public message: string, public severity: number = 0) {}
    },
    DiagnosticTag: { Unnecessary: 1, Deprecated: 2 },
    DiagnosticRelatedInformation: class {
      constructor(public location: unknown, public message: string) {}
    },
    CodeAction: class {
      edit?: unknown
      diagnostics?: unknown[]
      command?: unknown
      isPreferred?: boolean
      constructor(public title: string, public kind?: string) {}
    },
    CodeLens: class {
      constructor(public range: unknown, public command?: unknown) {}
      get isResolved(): boolean { return !!this.command }
    },
    SignatureHelp: class {
      signatures: unknown[] = []
      activeSignature = 0
      activeParameter = 0
    },
    SignatureInformation: class {
      parameters: unknown[] = []
      documentation?: unknown
      constructor(public label: string, documentation?: unknown) {
        this.documentation = documentation
      }
    },
    ParameterInformation: class {
      constructor(public label: string | [number, number], public documentation?: unknown) {}
    },
    FoldingRange: class {
      constructor(public start: number, public end: number, public kind?: number) {}
    },
    FoldingRangeKind: { Comment: 1, Imports: 2, Region: 3 },
    TreeItem: class {
      constructor(public label: string | { label: string }, public collapsibleState = 0) {}
    },
    Color: class {
      constructor(public red: number, public green: number, public blue: number, public alpha: number) {}
    },
    ColorInformation: class {
      constructor(public range: unknown, public color: unknown) {}
    },
    ColorPresentation: class {
      constructor(public label: string) {}
    },
    SemanticTokens: class {
      constructor(public data: Uint32Array, public resultId?: string) {}
    },
    SemanticTokensBuilder: class {
      private tokens: number[] = []
      push(...args: number[]): void { this.tokens.push(...args) }
      build(): unknown { return { data: new Uint32Array(this.tokens) } }
    },
    CommentThreadCollapsibleState: { Collapsed: 0, Expanded: 1 },
    CommentMode: { Editing: 0, Preview: 1 },
    CancellationError: class extends Error {
      constructor() {
        super('Canceled')
        this.name = 'Canceled'
      }
    },
    FileSystemError: class extends Error {
      code: string
      constructor(messageOrUri?: string | Uri, code = 'Unknown') {
        super(typeof messageOrUri === 'string' ? messageOrUri : messageOrUri?.toString())
        this.code = code
        this.name = 'FileSystemError'
      }
      static FileNotFound = (uri?: Uri): Error => new (vscode.FileSystemError as any)(uri, 'FileNotFound')
      static FileExists = (uri?: Uri): Error => new (vscode.FileSystemError as any)(uri, 'FileExists')
      static FileNotADirectory = (uri?: Uri): Error => new (vscode.FileSystemError as any)(uri, 'FileNotADirectory')
      static FileIsADirectory = (uri?: Uri): Error => new (vscode.FileSystemError as any)(uri, 'FileIsADirectory')
      static NoPermissions = (uri?: Uri): Error => new (vscode.FileSystemError as any)(uri, 'NoPermissions')
      static Unavailable = (uri?: Uri): Error => new (vscode.FileSystemError as any)(uri, 'Unavailable')
    },
    CodeActionKind: {
      Empty: '',
      QuickFix: 'quickfix',
      Refactor: 'refactor',
      Source: 'source'
    },
    env: {
      appName: 'Lithe',
      appRoot: resolveAppRoot(opts.storageRoot, log),
      appHost: 'desktop',
      machineId: createHash('sha256').update(os.hostname()).digest('hex').slice(0, 32),
      sessionId: randomUUID(),
      language: 'zh-cn',
      clipboard: {
        readText: async () => {
          try {
            return (require('electron') as typeof import('electron')).clipboard.readText()
          } catch {
            return ''
          }
        },
        writeText: async (value: string) => {
          try {
            ;(require('electron') as typeof import('electron')).clipboard.writeText(String(value ?? ''))
          } catch {
            /* ignore */
          }
        }
      },
      openExternal: async (uri: Uri) => {
        const { shell } = require('electron')
        await shell.openExternal(uri.toString())
        return true
      },
      uriScheme: 'lithe',
      uiKind: 1,
      remoteName: undefined,
      shell: process.env.ComSpec || process.env.SHELL || ''
    },
    workspace: stubMissing(
      {
      workspaceFolders,
      name: workspaceFolders[0]?.name,
      workspaceFile: undefined,
      getWorkspaceFolder: (uri: Uri) => {
        const fp = uri.fsPath
        return workspaceFolders.find((f) => fp.startsWith(f.uri.fsPath)) || workspaceFolders[0]
      },
      getConfiguration: (section?: string) => {
        const prefix = section ? `${section}.` : ''
        const fullKey = (key: string): string => `${prefix}${key}`
        return {
          get: <T>(key: string, defaultValue?: T): T => {
            const k = fullKey(key)
            return (Object.prototype.hasOwnProperty.call(configStore, k)
              ? configStore[k]
              : defaultValue) as T
          },
          has: (key: string) => Object.prototype.hasOwnProperty.call(configStore, fullKey(key)),
          inspect: (key: string) => ({
            key: fullKey(key),
            globalValue: configStore[fullKey(key)],
            defaultValue: undefined
          }),
          update: async (key: string, value: unknown) => {
            const k = fullKey(key)
            if (value === undefined) delete configStore[k]
            else configStore[k] = value
            await persistConfig()
            onDidChangeConfiguration.fire({
              affectsConfiguration: (s: string) => k === s || k.startsWith(`${s}.`)
            })
          }
        }
      },
      onDidChangeConfiguration: onDidChangeConfiguration.event,
      onDidChangeWorkspaceFolders: new Emitter<unknown>().event,
      onDidOpenTextDocument: new Emitter<unknown>().event,
      onDidCloseTextDocument: new Emitter<unknown>().event,
      onDidChangeTextDocument: new Emitter<unknown>().event,
      onDidSaveTextDocument: new Emitter<unknown>().event,
      onDidCreateFiles: new Emitter<unknown>().event,
      onDidDeleteFiles: new Emitter<unknown>().event,
      onDidRenameFiles: new Emitter<unknown>().event,
      textDocuments: [],
      fs: {
        readFile: async (uri: Uri) => new Uint8Array(await fs.promises.readFile(uri.fsPath)),
        writeFile: async (uri: Uri, content: Uint8Array) => {
          await fs.promises.mkdir(path.dirname(uri.fsPath), { recursive: true })
          await fs.promises.writeFile(uri.fsPath, content)
        },
        stat: async (uri: Uri) => {
          const st = await fs.promises.stat(uri.fsPath)
          return {
            type: st.isDirectory() ? 2 : 1,
            ctime: st.ctimeMs,
            mtime: st.mtimeMs,
            size: st.size
          }
        },
        readDirectory: async (uri: Uri) => {
          const entries = await fs.promises.readdir(uri.fsPath, { withFileTypes: true })
          return entries.map((e) => [e.name, e.isDirectory() ? 2 : 1] as [string, number])
        },
        createDirectory: async (uri: Uri) => fs.promises.mkdir(uri.fsPath, { recursive: true }),
        delete: async (uri: Uri) => fs.promises.rm(uri.fsPath, { recursive: true, force: true }),
        rename: async (src: Uri, dst: Uri) => fs.promises.rename(src.fsPath, dst.fsPath)
      },
      openTextDocument: async (uriOrOpts?: Uri | string | { language?: string; content?: string }) => {
        let filePath: string | undefined
        let content = ''
        let language = 'plaintext'
        if (typeof uriOrOpts === 'string') {
          filePath = uriOrOpts
        } else if (uriOrOpts instanceof Uri) {
          filePath = uriOrOpts.fsPath
        } else if (uriOrOpts && typeof uriOrOpts === 'object') {
          language = (uriOrOpts as any).language || 'plaintext'
          content = (uriOrOpts as any).content || ''
        }
        if (filePath) {
          try {
            content = await fs.promises.readFile(filePath, 'utf8')
          } catch {
            content = ''
          }
          const ext = path.extname(filePath).slice(1)
          language = ext || 'plaintext'
        }
        const lineCount = content.split('\n').length
        const lines = content.split('\n')
        return {
          uri: filePath ? Uri.file(filePath) : Uri.file('Untitled'),
          fileName: filePath || 'Untitled',
          languageId: language,
          lineCount,
          isUntitled: !filePath,
          version: 1,
          isDirty: false,
          isClosed: false,
          getText: (range?: unknown) => {
            if (!range) return content
            return content
          },
          lineAt: (lineOrPos: number | { line: number }) => {
            const ln = typeof lineOrPos === 'number' ? lineOrPos : lineOrPos.line
            const text = lines[ln] || ''
            return {
              text,
              lineNumber: ln,
              range: { start: { line: ln, character: 0 }, end: { line: ln, character: text.length } },
              rangeIncludingLineBreak: { start: { line: ln, character: 0 }, end: { line: ln + 1, character: 0 } },
              firstNonWhitespaceCharacterIndex: text.search(/\S/),
              isEmptyOrWhitespace: text.trim().length === 0
            }
          },
          positionAt: (offset: number) => {
            let line = 0
            let c = 0
            for (let i = 0; i < offset && i < content.length; i++) {
              if (content[i] === '\n') { line++; c = 0 } else { c++ }
            }
            return { line, character: c }
          },
          offsetAt: (position: { line: number; character: number }) => {
            let offset = 0
            for (let l = 0; l < position.line && l < lines.length; l++) {
              offset += lines[l].length + 1
            }
            return offset + position.character
          },
          getWordRangeAtPosition: () => undefined,
          save: async () => {
            if (filePath) {
              await fs.promises.writeFile(filePath, content, 'utf8')
              return true
            }
            return false
          }
        }
      },
      applyEdit: async (edit: any) => {
        // WorkspaceEdit → apply text edits to disk so agent file changes persist.
        try {
          const entries: Array<[Uri, any[]]> =
            edit && typeof edit.entries === 'function' ? edit.entries() : []
          if (!entries.length) return true

          const posToOffset = (text: string, pos: any): number => {
            if (!pos) return 0
            const line = pos.line ?? 0
            const character = pos.character ?? 0
            const lines = text.split('\n')
            let offset = 0
            for (let l = 0; l < line && l < lines.length; l++) offset += lines[l].length + 1
            return offset + character
          }

          for (const [uri, edits] of entries) {
            const filePath = uri.fsPath
            let content = ''
            try {
              content = await fs.promises.readFile(filePath, 'utf8')
            } catch {
              content = ''
            }
            const resolved = edits
              .map((e) => {
                const range = e?.range
                // range may be a Range ({start,end}) or a bare Position (insert)
                const start = range?.start ?? range
                const end = range?.end ?? range?.start ?? range
                return {
                  start: posToOffset(content, start),
                  end: posToOffset(content, end),
                  text: String(e?.newText ?? '')
                }
              })
              .sort((a, b) => b.start - a.start)
            for (const e of resolved) {
              content = content.slice(0, e.start) + e.text + content.slice(e.end)
            }
            await fs.promises.mkdir(path.dirname(filePath), { recursive: true })
            await fs.promises.writeFile(filePath, content, 'utf8')
          }
          return true
        } catch (err) {
          log(`[host] applyEdit failed: ${String(err)}`)
          return false
        }
      },
      asRelativePath: (uriOrPath: Uri | string) => {
        const p = typeof uriOrPath === 'string' ? uriOrPath : uriOrPath.fsPath
        if (!opts.cwd) return p
        return path.relative(opts.cwd, p) || p
      },
      createFileSystemWatcher: () => ({
        onDidCreate: new Emitter<Uri>().event,
        onDidChange: new Emitter<Uri>().event,
        onDidDelete: new Emitter<Uri>().event,
        dispose: () => {}
      }),
      findFiles: async (include?: unknown, exclude?: unknown, maxResults?: number) => {
        // Support the common `**/glob` / RelativePattern cases against the workspace.
        if (!opts.cwd) return []
        const patternOf = (p: unknown): string => {
          if (typeof p === 'string') return p
          if (p && typeof p === 'object' && typeof (p as any).pattern === 'string') {
            return (p as any).pattern
          }
          return '**/*'
        }
        const globToRegExp = (glob: string): RegExp => {
          let re = ''
          for (let i = 0; i < glob.length; i++) {
            const ch = glob[i]
            if (ch === '*') {
              if (glob[i + 1] === '*') {
                re += '.*'
                i++
                if (glob[i + 1] === '/') i++
              } else {
                re += '[^/]*'
              }
            } else if (ch === '?') re += '[^/]'
            else if (ch === '{') re += '('
            else if (ch === '}') re += ')'
            else if (ch === ',') re += '|'
            else re += ch.replace(/[.+^$()|[\]\\]/g, '\\$&')
          }
          return new RegExp(`^${re}$`, process.platform === 'win32' ? 'i' : '')
        }

        const includeRe = globToRegExp(patternOf(include))
        const excludeRe = exclude ? globToRegExp(patternOf(exclude)) : null
        const skipDirs = new Set([
          '.git', 'node_modules', 'target', 'build', 'dist', 'out', '.gradle', '.idea', '.venv',
          '__pycache__', '.next', '.turbo', 'vendor'
        ])
        const limit = typeof maxResults === 'number' && maxResults > 0 ? maxResults : 5000
        const results: Uri[] = []

        const walk = async (dir: string): Promise<void> => {
          if (results.length >= limit) return
          let entries: fs.Dirent[]
          try {
            entries = await fs.promises.readdir(dir, { withFileTypes: true })
          } catch {
            return
          }
          for (const entry of entries) {
            if (results.length >= limit) return
            const abs = path.join(dir, entry.name)
            if (entry.isDirectory()) {
              if (skipDirs.has(entry.name)) continue
              await walk(abs)
            } else if (entry.isFile()) {
              const rel = path.relative(opts.cwd!, abs).replace(/\\/g, '/')
              if (!includeRe.test(rel)) continue
              if (excludeRe && excludeRe.test(rel)) continue
              results.push(Uri.file(abs))
            }
          }
        }

        await walk(opts.cwd)
        return results
      },
      saveAll: async () => true
    },
      'workspace'
    ),
    window: stubMissing(
      {
      showInformationMessage: async (msg: string, ..._rest: unknown[]) => {
        log(`[info] ${msg}`)
        // No modal surface in Lithe yet — treat as dismissed rather than
        // silently clicking a button on the user's behalf.
        return undefined
      },
      showWarningMessage: async (msg: string, ..._rest: unknown[]) => {
        log(`[warn] ${msg}`)
        return undefined
      },
      showErrorMessage: async (msg: string, ..._rest: unknown[]) => {
        log(`[error] ${msg}`)
        return undefined
      },
      showInputBox: async () => undefined,
      showQuickPick: async () => undefined,
      showOpenDialog: async (options?: any) => {
        try {
          const { dialog, BrowserWindow } = require('electron') as typeof import('electron')
          const props: Array<'openFile' | 'openDirectory' | 'multiSelections'> = []
          if (options?.canSelectFolders) props.push('openDirectory')
          if (options?.canSelectFiles !== false && !options?.canSelectFolders) props.push('openFile')
          if (options?.canSelectMany) props.push('multiSelections')
          const win = BrowserWindow.getFocusedWindow() || BrowserWindow.getAllWindows()[0]
          const dialogOpts = {
            properties: props.length ? props : (['openFile'] as Array<'openFile'>),
            defaultPath: options?.defaultUri?.fsPath,
            title: options?.title,
            buttonLabel: options?.openLabel,
            filters: options?.filters
              ? Object.entries(options.filters).map(([name, exts]) => ({
                  name,
                  extensions: (exts as string[]).map((e) => e.replace(/^\./, ''))
                }))
              : undefined
          }
          const res = win
            ? await dialog.showOpenDialog(win, dialogOpts as any)
            : await dialog.showOpenDialog(dialogOpts as any)
          if (res.canceled || !res.filePaths.length) return undefined
          return res.filePaths.map((p) => Uri.file(p))
        } catch (err: any) {
          log(`[host] showOpenDialog failed: ${err?.message || err}`)
          return undefined
        }
      },
      showSaveDialog: async (options?: any) => {
        try {
          const { dialog, BrowserWindow } = require('electron') as typeof import('electron')
          const win = BrowserWindow.getFocusedWindow() || BrowserWindow.getAllWindows()[0]
          const dialogOpts = {
            defaultPath: options?.defaultUri?.fsPath,
            title: options?.title,
            buttonLabel: options?.saveLabel,
            filters: options?.filters
              ? Object.entries(options.filters).map(([name, exts]) => ({
                  name,
                  extensions: (exts as string[]).map((e) => e.replace(/^\./, ''))
                }))
              : undefined
          }
          const res = win
            ? await dialog.showSaveDialog(win, dialogOpts as any)
            : await dialog.showSaveDialog(dialogOpts as any)
          if (res.canceled || !res.filePath) return undefined
          return Uri.file(res.filePath)
        } catch (err: any) {
          log(`[host] showSaveDialog failed: ${err?.message || err}`)
          return undefined
        }
      },
      showTextDocument: async (docOrUri?: any, _options?: any) => {
        const uri = docOrUri instanceof Uri
          ? docOrUri
          : (docOrUri?.uri instanceof Uri ? docOrUri.uri : undefined)
        if (uri) {
          opts.onLitheAction?.('openFile', { path: uri.fsPath })
        }
        return undefined
      },
      createOutputChannel: (name: string) => {
        const ch = {
          name,
          append: (s: string) => log(`[${name}] ${s}`),
          appendLine: (s: string) => log(`[${name}] ${s}`),
          clear: () => {},
          show: () => {},
          hide: () => {},
          dispose: () => {},
          replace: () => {}
        }
        outputChannels.push(ch)
        return ch
      },
      createStatusBarItem: () => ({
        text: '',
        tooltip: '',
        command: undefined,
        show: () => {},
        hide: () => {},
        dispose: () => {}
      }),
      createTerminal: (nameOrOpts?: string | { name?: string; cwd?: string | Uri; shellPath?: string; shellArgs?: string[] }) => {
        const termOpts = typeof nameOrOpts === 'string' ? { name: nameOrOpts } : (nameOrOpts || {})
        const termName = termOpts.name || 'Lithe'
        const termCwd = termOpts.cwd
          ? (typeof termOpts.cwd === 'string' ? termOpts.cwd : termOpts.cwd.fsPath)
          : (opts.cwd || process.cwd())
        const shellExe = termOpts.shellPath || process.env.ComSpec || process.env.SHELL || '/bin/sh'
        const shellArgs = termOpts.shellArgs || []

        let cp: import('child_process').ChildProcess | null = null
        const ensureSpawned = (): void => {
          if (cp) return
          try {
            const { spawn } = require('child_process') as typeof import('child_process')
            cp = spawn(shellExe, shellArgs, {
              cwd: termCwd,
              env: { ...process.env, TERM: 'dumb' },
              shell: false,
              stdio: ['pipe', 'pipe', 'pipe'],
              windowsHide: true
            })
            cp.stdout?.on('data', (data: Buffer) => log(`[terminal:${termName}:stdout] ${data.toString()}`))
            cp.stderr?.on('data', (data: Buffer) => log(`[terminal:${termName}:stderr] ${data.toString()}`))
            cp.on('exit', (code) => log(`[terminal:${termName}] exited ${code}`))
          } catch (err: any) {
            log(`[terminal:${termName}] spawn failed: ${err?.message || err}`)
          }
        }

        const processId: Promise<number | undefined> = Promise.resolve(undefined)

        return {
          name: termName,
          processId,
          creationOptions: termOpts,
          exitStatus: undefined,
          state: { isInteractedWith: false },
          sendText: (text: string, addNewline = true) => {
            ensureSpawned()
            const cmd = addNewline !== false ? text + '\n' : text
            try {
              cp?.stdin?.write(cmd)
            } catch (err: any) {
              log(`[terminal:${termName}] write error: ${err?.message}`)
            }
          },
          show: () => {},
          hide: () => {},
          dispose: () => {
            try { cp?.kill() } catch { /* ignore */ }
            cp = null
          }
        }
      },
      createTextEditorDecorationType: (_options?: unknown) => ({
        key: `dec-${Math.random().toString(36).slice(2)}`,
        dispose: () => {}
      }),
      createWebviewPanel: () => {
        throw new Error('createWebviewPanel is not hosted in Lithe sidebar mode')
      },
      registerWebviewViewProvider: (viewType: string, provider: WebviewViewProvider, _options?: unknown) => {
        providers.set(viewType, provider)
        log(`[host] registered WebviewViewProvider: ${viewType}`)
        return toDisposable(() => providers.delete(viewType))
      },
      registerTreeDataProvider: () => toDisposable(() => {}),
      registerUriHandler: () => toDisposable(() => {}),
      registerWebviewPanelSerializer: () => toDisposable(() => {}),
      registerFileDecorationProvider: () => toDisposable(() => {}),
      registerCustomEditorProvider: () => toDisposable(() => {}),
      onDidChangeActiveTextEditor: new Emitter<unknown>().event,
      onDidChangeVisibleTextEditors: new Emitter<unknown>().event,
      onDidChangeWindowState: new Emitter<unknown>().event,
      onDidChangeActiveColorTheme: new Emitter<unknown>().event,
      onDidChangeTextEditorSelection: new Emitter<unknown>().event,
      onDidChangeTextEditorVisibleRanges: new Emitter<unknown>().event,
      activeTextEditor: undefined,
      visibleTextEditors: [],
      activeColorTheme: { kind: 2 },
      state: { focused: true },
      tabGroups: {
        all: [],
        activeTabGroup: { tabs: [], isActive: true, viewColumn: 1 },
        onDidChangeTabs: new Emitter<unknown>().event,
        onDidChangeTabGroups: new Emitter<unknown>().event,
        close: async () => true
      },
      withProgress: async (_opts: unknown, task: (progress: unknown, token: unknown) => unknown) =>
        task({ report: () => {} }, { isCancellationRequested: false, onCancellationRequested: new Emitter<void>().event }),
      createQuickPick: () => ({
        items: [],
        value: '',
        placeholder: '',
        onDidAccept: new Emitter<void>().event,
        onDidHide: new Emitter<void>().event,
        onDidChangeSelection: new Emitter<unknown>().event,
        show: () => {},
        hide: () => {},
        dispose: () => {}
      }),
      createInputBox: () => ({
        value: '',
        placeholder: '',
        onDidAccept: new Emitter<void>().event,
        onDidHide: new Emitter<void>().event,
        show: () => {},
        hide: () => {},
        dispose: () => {}
      })
    },
      'window'
    ),
    commands: {
      registerCommand: (id: string, callback: (...args: unknown[]) => unknown) => {
        commandMap.set(id, callback)
        return toDisposable(() => commandMap.delete(id))
      },
      executeCommand: async (id: string, ...args: unknown[]) => {
        const fn = commandMap.get(id)
        if (fn) return fn(...args)
        // Common workbench commands — no-op instead of throw
        if (
          id === 'setContext' ||
          id === 'getContext' ||
          id.startsWith('workbench.') ||
          id.startsWith('vscode.') ||
          id.startsWith('editor.') ||
          id.startsWith('_workbench.') ||
          id.endsWith('.focus') ||
          id.includes('openWalkthrough')
        ) {
          log(`[host] ignored command: ${id}`)
          return undefined
        }
        log(`[host] executeCommand missing: ${id}`)
        return undefined
      },
      getCommands: async () => [...commandMap.keys()],
      registerTextEditorCommand: (id: string, callback: (...args: unknown[]) => unknown) => {
        commandMap.set(id, callback)
        return toDisposable(() => commandMap.delete(id))
      }
    },
    languages: stubMissing(
      {
      registerCompletionItemProvider: () => toDisposable(() => {}),
      registerCodeActionsProvider: () => toDisposable(() => {}),
      registerHoverProvider: () => toDisposable(() => {}),
      registerDefinitionProvider: () => toDisposable(() => {}),
      registerDocumentFormattingEditProvider: () => toDisposable(() => {}),
      registerDocumentSymbolProvider: () => toDisposable(() => {}),
      registerCodeLensProvider: () => toDisposable(() => {}),
      registerInlineCompletionItemProvider: () => toDisposable(() => {}),
      createDiagnosticCollection: () => ({
        set: () => {},
        delete: () => {},
        clear: () => {},
        dispose: () => {},
        name: 'lithe'
      }),
      getDiagnostics: () => [],
      match: () => 0,
      onDidChangeDiagnostics: new Emitter<unknown>().event
    },
      'languages'
    ),
    extensions: {
      getExtension: (id?: string) => {
        // Many extensions getExtension(own-id) to read their own package.json
        if (!id || id === opts.pluginId) {
          const pkg = (() => {
            try { return JSON.parse(fs.readFileSync(path.join(opts.extensionPath, 'package.json'), 'utf8')) } catch { return {} }
          })()
          return {
            id: opts.pluginId,
            extensionUri,
            extensionPath: opts.extensionPath,
            isActive: true,
            packageJSON: pkg,
            extensionKind: 1,
            exports: undefined,
            activate: async () => ({})
          }
        }
        return undefined
      },
      all: [],
      onDidChange: new Emitter<unknown>().event
    },
    debug: {
      onDidStartDebugSession: new Emitter<unknown>().event,
      onDidTerminateDebugSession: new Emitter<unknown>().event,
      registerDebugAdapterDescriptorFactory: () => toDisposable(() => {})
    },
    tasks: {
      registerTaskProvider: () => toDisposable(() => {})
    },
    scm: {
      createSourceControl: () => ({
        createResourceGroup: () => ({ dispose: () => {} }),
        dispose: () => {}
      })
    },
    comments: {
      createCommentController: () => ({ dispose: () => {} })
    },
    notebooks: {
      registerNotebookSerializer: () => toDisposable(() => {})
    },
    l10n: {
      t: (msg: string) => msg
    }
  }

  const context = {
    subscriptions: [] as Disposable[],
    extensionUri,
    extensionPath: opts.extensionPath,
    extension: {
      id: opts.pluginId,
      extensionUri,
      extensionPath: opts.extensionPath,
      isActive: true,
      packageJSON: (() => {
        try {
          return JSON.parse(fs.readFileSync(path.join(opts.extensionPath, 'package.json'), 'utf8'))
        } catch {
          return {}
        }
      })()
    },
    extensionMode: 1,
    extensionKind: 1,
    storageUri: Uri.file(path.join(opts.storageRoot, 'storage')),
    storagePath: path.join(opts.storageRoot, 'storage'),
    globalStorageUri: Uri.file(path.join(opts.storageRoot, 'global-storage')),
    globalStoragePath: path.join(opts.storageRoot, 'global-storage'),
    logUri: Uri.file(path.join(opts.storageRoot, 'logs')),
    logPath: path.join(opts.storageRoot, 'logs'),
    globalState,
    workspaceState,
    secrets,
    environmentVariableCollection: {
      persistent: true,
      replace: () => {},
      append: () => {},
      prepend: () => {},
      get: () => undefined,
      forEach: () => {},
      delete: () => {},
      clear: () => {}
    },
    asAbsolutePath: (rel: string) => path.join(opts.extensionPath, rel),
    languageModelAccessInformation: {
      onDidChange: new Emitter<unknown>().event,
      canSendRequest: () => true
    }
  }

  const createWebviewView = (viewType: string): ShimWebviewView => {
    const webview = new ShimWebview(opts.extensionPath, toHttpUrl, cspSource, opts.onPostToWebview)
    webview.options = {
      enableScripts: true,
      localResourceRoots: [extensionUri]
    }
    return new ShimWebviewView(webview, viewType)
  }

  /**
   * Last-resort stub for a top-level `vscode.X` this shim doesn't implement.
   *
   * Returns a *function-backed Proxy* rather than `undefined`, because the two
   * ways activate() dies on a missing API are:
   *   `new vscode.Missing()`        → "Missing is not a constructor"
   *   `x instanceof vscode.Missing` → "Right-hand side of 'instanceof' is not an object"
   * A callable/constructable target satisfies both. `Symbol.hasInstance` is
   * pinned to false so instanceof answers cleanly instead of throwing, and
   * nested access (`vscode.Missing.Nested()`) keeps resolving to stubs.
   */
  const makeUniversalStub = (label: string): any => {
    const target = function (): unknown {
      return {}
    }
    Object.defineProperty(target, 'name', { value: label.split('.').pop() || label })
    return new Proxy(target, {
      get(obj, prop, receiver) {
        if (prop === Symbol.hasInstance) return () => false
        if (prop === 'toString') return () => `[LitheStub ${label}]`
        if (prop === Symbol.toPrimitive) return () => `[LitheStub ${label}]`
        if (typeof prop === 'symbol') return Reflect.get(obj, prop, receiver)
        if (prop === 'prototype' || prop === 'name' || prop === 'length') {
          return Reflect.get(obj, prop, receiver)
        }
        const name = String(prop)
        if (name.startsWith('onDid') || name.startsWith('onWill')) {
          return new Emitter<unknown>().event
        }
        return makeUniversalStub(`${label}.${name}`)
      },
      construct() {
        return {}
      },
      apply() {
        return undefined
      }
    })
  }

  // Guard the top-level namespace. Inner namespaces (workspace/window/languages)
  // already self-stub via stubMissing; this covers classes and enums.
  const guardedVscode = new Proxy(vscode as Record<string, unknown>, {
    get(obj, prop, receiver) {
      if (prop in obj || typeof prop === 'symbol') {
        return Reflect.get(obj, prop, receiver)
      }
      const name = String(prop)
      log(`[host] stub vscode.${name} (unimplemented API)`)
      const stub = makeUniversalStub(`vscode.${name}`)
      obj[name] = stub
      return stub
    },
    has() {
      // Extensions probe with `'X' in vscode` for capability detection; the
      // shim can always produce something, so report support.
      return true
    }
  })

  return {
    vscode: guardedVscode,
    context,
    getRegisteredProvider: (viewType) => providers.get(viewType),
    getRegisteredViewTypes: () => [...providers.keys()],
    createWebviewView,
    executeCommand: (id: string, ...args: unknown[]) => {
      const fn = commandMap.get(id)
      if (!fn) return undefined
      return fn(...args)
    },
    hasCommand: (id: string) => commandMap.has(id)
  }
}
