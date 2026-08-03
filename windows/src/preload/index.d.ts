import { ElectronAPI } from '@electron-toolkit/preload'

interface LitheAPI {
  readFile: (path: string) => Promise<{
    content: string
    binary?: boolean
    size?: number
    sizeLabel?: string
    mtimeMs: number
    isReadOnly: boolean
  }>
  writeFile: (path: string, content: string) => Promise<{ mtimeMs: number }>
  fileExists: (path: string) => Promise<boolean>
  fileStat: (path: string) => Promise<{ size: number; mtimeMs: number; isDirectory: boolean; isFile: boolean }>
  deleteFile: (path: string) => Promise<void>
  renameFile: (oldPath: string, newPath: string) => Promise<void>
  createFile: (targetPath: string, opts?: { directory?: boolean; content?: string }) => Promise<string>
  revealInFolder: (targetPath: string) => Promise<void>
  pickDirectory: () => Promise<string | null>
  openProjectDialog: () => Promise<string | null>
  scanProject: (dir: string, hidden?: string[]) => Promise<any>
  watchStart: (dir: string, key: string) => Promise<void>
  watchStop: (key: string) => Promise<void>
  recentList: () => Promise<any[]>
  recentAdd: (dir: string) => Promise<any[]>
  recentRemove: (dir: string) => Promise<any[]>
  onWatchEvent: (cb: (data: any) => void) => void
  terminalCreate: (id: string, cwd: string, shell?: string, cols?: number, rows?: number) => Promise<{
    cwd: string
    shell?: string
    interactive?: boolean
  }>
  terminalWrite: (id: string, data: string) => Promise<void>
  terminalResize: (id: string, cols: number, rows: number) => Promise<void>
  terminalDestroy: (id: string) => Promise<void>
  terminalExec: (id: string, command: string) => Promise<void>
  terminalComplete: (id: string, line: string) => Promise<{ replacements: string[]; replaceFrom: number }>
  terminalCd: (id: string, target: string) => Promise<{ cwd: string }>
  terminalCwd: (id: string) => Promise<string>
  terminalInterrupt: (id: string) => Promise<void>
  onTerminalData: (cb: (data: any) => void) => void
  onTerminalExit: (cb: (data: any) => void) => void
  localServerStart: (root: string, port?: number) => Promise<{ url: string; port: number; root: string; already: boolean }>
  localServerStop: () => Promise<{ stopped: boolean }>
  localServerStatus: () => Promise<{ running: boolean; url?: string; port?: number; root?: string }>
  localServerOpen: () => Promise<{ url: string }>
  gitStatus: (cwd: string) => Promise<any>
  gitLog: (cwd: string, max?: number) => Promise<any[]>
  gitDiff: (cwd: string, file?: string, staged?: boolean) => Promise<string>
  gitBranchList: (cwd: string) => Promise<Array<{ name: string; hash: string; isCurrent: boolean }>>
  gitBranchSwitch: (cwd: string, name: string) => Promise<void>
  gitBranchCreate: (cwd: string, name: string, checkout?: boolean) => Promise<void>
  gitBranchDelete: (cwd: string, name: string, force?: boolean) => Promise<void>
  gitCommit: (cwd: string, msg: string, amend?: boolean) => Promise<void>
  gitStage: (cwd: string, files: string[]) => Promise<void>
  gitUnstage: (cwd: string, files: string[]) => Promise<void>
  gitDiscard: (cwd: string, files: string[]) => Promise<void>
  gitStashList: (cwd: string) => Promise<Array<{ index: number; ref: string; message: string; date: string }>>
  gitStashSave: (cwd: string, message?: string) => Promise<void>
  gitStashApply: (cwd: string, index?: number, pop?: boolean) => Promise<void>
  gitStashDrop: (cwd: string, index?: number) => Promise<void>
  gitClone: (url: string, dest: string) => Promise<void>
  onGitCloneProgress: (cb: (msg: string) => void) => void
  localHistoryList: (filePath: string) => Promise<Array<{ timestamp: number; fileName: string }>>
  localHistoryGet: (fileName: string) => Promise<{ timestamp: number; path: string; content: string }>
  localHistorySave: (filePath: string, content: string) => Promise<void>
  localHistoryRestore: (historyFileName: string) => Promise<{ timestamp: number; path: string; content: string }>
  settingsGet: () => Promise<any>
  settingsSet: (partial: Record<string, unknown>) => Promise<any>
  discoverJdks: () => Promise<any[]>
  discoverMaven: (dir: string) => Promise<string | null>
  javaRun: (id: string, config: any) => Promise<void>
  mavenRun: (id: string, config: any) => Promise<void>
  mavenScanModules: (dir: string) => Promise<any[]>
  onJavaOutput: (cb: (data: any) => void) => void
  onJavaExit: (cb: (data: any) => void) => void
  pluginList: () => Promise<import('../common/types').PluginInfo[]>
  pluginSetEnabled: (id: string, enabled: boolean) => Promise<import('../common/types').PluginInfo[]>
  pluginUninstall: (id: string) => Promise<import('../common/types').PluginInfo[]>
  pluginInstallPath: (target: string) => Promise<import('../common/types').PluginInfo>
  pluginInstallDialog: () => Promise<import('../common/types').PluginInfo | null>
  pluginSearchMarket: (
    kind: string,
    query: string
  ) => Promise<import('../common/types').MarketplacePlugin[]>
  pluginListVersions: (
    kind: string,
    id: string,
    extra?: Record<string, string>
  ) => Promise<import('../common/types').MarketplaceVersion[]>
  pluginInstallMarket: (
    kind: string,
    id: string,
    extra?: Record<string, string>
  ) => Promise<import('../common/types').PluginInfo>
  pluginExportMarket: (
    kind: string,
    id: string,
    extra?: Record<string, string>
  ) => Promise<import('../common/types').MarketplaceExportResult>
  pluginExportInstalled: (id: string) => Promise<import('../common/types').MarketplaceExportResult>
  pluginContributions: () => Promise<{
    plugins: import('../common/types').PluginInfo[]
    themes: Array<import('../common/types').PluginThemeContribution & { pluginId: string; pluginName: string }>
    commands: Array<import('../common/types').PluginCommandContribution & { pluginId: string; pluginName: string }>
    views: Array<
      import('../common/types').PluginViewContribution & {
        pluginId: string
        pluginName: string
        pluginKind: import('../common/types').PluginKind
      }
    >
    themeContents: Record<string, unknown>
  }>
  pluginWebviewUrl: (
    id: string,
    cwd?: string
  ) => Promise<{
    ok: true
    url: string
    title: string
    hostStatus?: string
    hostError?: string
  } | { ok: false; error?: string }>
  pluginHostEnsure: (
    id: string,
    cwd?: string
  ) => Promise<{ ok: boolean; status: string; error?: string; viewType?: string }>
  pluginHostPost: (id: string, message: unknown) => Promise<{ ok: boolean }>
  onPluginHostEvent: (
    cb: (payload: { pluginId: string; message: unknown }) => void
  ) => () => void
  pluginOpenFolder: () => Promise<string>
  removeAllListeners: (channel: string) => void
}

declare global {
  interface Window {
    electron: ElectronAPI
    api: LitheAPI
  }
}
