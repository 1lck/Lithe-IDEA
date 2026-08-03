import { contextBridge, ipcRenderer } from 'electron'
import { electronAPI } from '@electron-toolkit/preload'
import { IPC } from '../common/ipc'

const api = {
  // File
  readFile: (path: string) => ipcRenderer.invoke(IPC.FILE_READ, path),
  writeFile: (path: string, content: string) => ipcRenderer.invoke(IPC.FILE_WRITE, path, content),
  fileExists: (path: string) => ipcRenderer.invoke(IPC.FILE_EXISTS, path),
  fileStat: (path: string) => ipcRenderer.invoke(IPC.FILE_STAT, path),
  deleteFile: (path: string) => ipcRenderer.invoke(IPC.FILE_DELETE, path),
  renameFile: (oldPath: string, newPath: string) => ipcRenderer.invoke(IPC.FILE_RENAME, oldPath, newPath),
  createFile: (targetPath: string, opts?: { directory?: boolean; content?: string }) =>
    ipcRenderer.invoke(IPC.FILE_CREATE, targetPath, opts),
  revealInFolder: (targetPath: string) => ipcRenderer.invoke(IPC.FILE_REVEAL, targetPath),
  pickDirectory: () => ipcRenderer.invoke(IPC.FILE_PICK_DIRECTORY),

  // Project
  openProjectDialog: () => ipcRenderer.invoke(IPC.PROJECT_OPEN_DIALOG),
  scanProject: (dir: string, hidden?: string[]) => ipcRenderer.invoke(IPC.PROJECT_SCAN, dir, hidden),
  watchStart: (dir: string, key: string) => ipcRenderer.invoke(IPC.PROJECT_WATCH_START, dir, key),
  watchStop: (key: string) => ipcRenderer.invoke(IPC.PROJECT_WATCH_STOP, key),
  recentList: () => ipcRenderer.invoke(IPC.PROJECT_RECENT_LIST),
  recentAdd: (dir: string) => ipcRenderer.invoke(IPC.PROJECT_RECENT_ADD, dir),
  recentRemove: (dir: string) => ipcRenderer.invoke(IPC.PROJECT_RECENT_REMOVE, dir),
  onWatchEvent: (cb: (data: any) => void) => ipcRenderer.on('project:watch-event', (_e, data) => cb(data)),

  // Terminal
  terminalCreate: (id: string, cwd: string, shell?: string, cols?: number, rows?: number) =>
    ipcRenderer.invoke(IPC.TERMINAL_CREATE, id, cwd, shell, cols, rows),
  terminalWrite: (id: string, data: string) => ipcRenderer.invoke(IPC.TERMINAL_WRITE, id, data),
  terminalResize: (id: string, cols: number, rows: number) =>
    ipcRenderer.invoke(IPC.TERMINAL_RESIZE, id, cols, rows),
  terminalDestroy: (id: string) => ipcRenderer.invoke(IPC.TERMINAL_DESTROY, id),
  terminalExec: (id: string, command: string) => ipcRenderer.invoke(IPC.TERMINAL_EXEC, id, command),
  terminalComplete: (id: string, line: string) => ipcRenderer.invoke(IPC.TERMINAL_COMPLETE, id, line),
  terminalCd: (id: string, target: string) => ipcRenderer.invoke(IPC.TERMINAL_CD, id, target),
  terminalCwd: (id: string) => ipcRenderer.invoke(IPC.TERMINAL_CWD, id),
  terminalInterrupt: (id: string) => ipcRenderer.invoke(IPC.TERMINAL_INTERRUPT, id),
  onTerminalData: (cb: (data: any) => void) => ipcRenderer.on(IPC.TERMINAL_DATA, (_e, data) => cb(data)),
  onTerminalExit: (cb: (data: any) => void) => ipcRenderer.on(IPC.TERMINAL_EXIT, (_e, data) => cb(data)),

  // Local server
  localServerStart: (root: string, port?: number) => ipcRenderer.invoke(IPC.LOCAL_SERVER_START, root, port),
  localServerStop: () => ipcRenderer.invoke(IPC.LOCAL_SERVER_STOP),
  localServerStatus: () => ipcRenderer.invoke(IPC.LOCAL_SERVER_STATUS),
  localServerOpen: () => ipcRenderer.invoke(IPC.LOCAL_SERVER_OPEN),

  // Git
  gitStatus: (cwd: string) => ipcRenderer.invoke(IPC.GIT_STATUS, cwd),
  gitLog: (cwd: string, max?: number) => ipcRenderer.invoke(IPC.GIT_LOG, cwd, max),
  gitDiff: (cwd: string, file?: string, staged?: boolean) => ipcRenderer.invoke(IPC.GIT_DIFF, cwd, file, staged),
  gitBranchList: (cwd: string) => ipcRenderer.invoke(IPC.GIT_BRANCH_LIST, cwd),
  gitBranchSwitch: (cwd: string, name: string) => ipcRenderer.invoke(IPC.GIT_BRANCH_SWITCH, cwd, name),
  gitBranchCreate: (cwd: string, name: string, checkout?: boolean) =>
    ipcRenderer.invoke(IPC.GIT_BRANCH_CREATE, cwd, name, checkout),
  gitBranchDelete: (cwd: string, name: string, force?: boolean) =>
    ipcRenderer.invoke(IPC.GIT_BRANCH_DELETE, cwd, name, force),
  gitCommit: (cwd: string, msg: string, amend?: boolean) =>
    ipcRenderer.invoke(IPC.GIT_COMMIT, cwd, msg, amend),
  gitStage: (cwd: string, files: string[]) => ipcRenderer.invoke(IPC.GIT_STAGE, cwd, files),
  gitUnstage: (cwd: string, files: string[]) => ipcRenderer.invoke(IPC.GIT_UNSTAGE, cwd, files),
  gitDiscard: (cwd: string, files: string[]) => ipcRenderer.invoke(IPC.GIT_DISCARD, cwd, files),
  gitStashList: (cwd: string) => ipcRenderer.invoke(IPC.GIT_STASH_LIST, cwd),
  gitStashSave: (cwd: string, message?: string) => ipcRenderer.invoke(IPC.GIT_STASH_SAVE, cwd, message),
  gitStashApply: (cwd: string, index?: number, pop?: boolean) =>
    ipcRenderer.invoke(IPC.GIT_STASH_APPLY, cwd, index, pop),
  gitStashDrop: (cwd: string, index?: number) => ipcRenderer.invoke(IPC.GIT_STASH_DROP, cwd, index),
  gitClone: (url: string, dest: string) => ipcRenderer.invoke(IPC.GIT_CLONE, url, dest),
  onGitCloneProgress: (cb: (msg: string) => void) => ipcRenderer.on('git:clone-progress', (_e, msg) => cb(msg)),

  // Local history
  localHistoryList: (filePath: string) => ipcRenderer.invoke(IPC.LOCAL_HISTORY_LIST, filePath),
  localHistoryGet: (fileName: string) => ipcRenderer.invoke(IPC.LOCAL_HISTORY_GET, fileName),
  localHistorySave: (filePath: string, content: string) =>
    ipcRenderer.invoke(IPC.LOCAL_HISTORY_SAVE, filePath, content),
  localHistoryRestore: (historyFileName: string) =>
    ipcRenderer.invoke(IPC.LOCAL_HISTORY_RESTORE, historyFileName),

  // Settings
  settingsGet: () => ipcRenderer.invoke(IPC.SETTINGS_GET),
  settingsSet: (partial: Record<string, unknown>) => ipcRenderer.invoke(IPC.SETTINGS_SET, partial),

  // Java / Maven
  discoverJdks: () => ipcRenderer.invoke(IPC.JAVA_DISCOVER_JDKS),
  discoverMaven: (dir: string) => ipcRenderer.invoke(IPC.MAVEN_DISCOVER, dir),
  javaRun: (id: string, config: any) => ipcRenderer.invoke(IPC.JAVA_RUN, id, config),
  mavenRun: (id: string, config: any) => ipcRenderer.invoke(IPC.MAVEN_RUN, id, config),
  mavenScanModules: (dir: string) => ipcRenderer.invoke(IPC.MAVEN_SCAN_MODULES, dir),
  onJavaOutput: (cb: (data: any) => void) => ipcRenderer.on('java:output', (_e, data) => cb(data)),
  onJavaExit: (cb: (data: any) => void) => ipcRenderer.on('java:exit', (_e, data) => cb(data)),

  // Plugins
  pluginList: () => ipcRenderer.invoke(IPC.PLUGIN_LIST),
  pluginSetEnabled: (id: string, enabled: boolean) =>
    ipcRenderer.invoke(IPC.PLUGIN_SET_ENABLED, id, enabled),
  pluginUninstall: (id: string) => ipcRenderer.invoke(IPC.PLUGIN_UNINSTALL, id),
  pluginInstallPath: (target: string) => ipcRenderer.invoke(IPC.PLUGIN_INSTALL_PATH, target),
  pluginInstallDialog: () => ipcRenderer.invoke(IPC.PLUGIN_INSTALL_DIALOG),
  pluginSearchMarket: (kind: string, query: string) =>
    ipcRenderer.invoke(IPC.PLUGIN_SEARCH_MARKET, kind, query),
  pluginListVersions: (kind: string, id: string, extra?: Record<string, string>) =>
    ipcRenderer.invoke(IPC.PLUGIN_LIST_VERSIONS, kind, id, extra),
  pluginInstallMarket: (kind: string, id: string, extra?: Record<string, string>) =>
    ipcRenderer.invoke(IPC.PLUGIN_INSTALL_MARKET, kind, id, extra),
  pluginExportMarket: (kind: string, id: string, extra?: Record<string, string>) =>
    ipcRenderer.invoke(IPC.PLUGIN_EXPORT_MARKET, kind, id, extra),
  pluginExportInstalled: (id: string) => ipcRenderer.invoke(IPC.PLUGIN_EXPORT_INSTALLED, id),
  pluginContributions: () => ipcRenderer.invoke(IPC.PLUGIN_CONTRIBUTIONS),
  pluginWebviewUrl: (id: string, cwd?: string) =>
    ipcRenderer.invoke(IPC.PLUGIN_WEBVIEW_URL, id, cwd),
  pluginHostEnsure: (id: string, cwd?: string) =>
    ipcRenderer.invoke(IPC.PLUGIN_HOST_ENSURE, id, cwd),
  pluginHostPost: (id: string, message: unknown) =>
    ipcRenderer.invoke(IPC.PLUGIN_HOST_POST, id, message),
  pluginExecuteCommand: (id: string, commandId: string, args?: unknown[]) =>
    ipcRenderer.invoke(IPC.PLUGIN_EXECUTE_COMMAND, id, commandId, args || []),
  onPluginHostEvent: (cb: (payload: { pluginId: string; message: unknown }) => void) => {
    const listener = (_event: unknown, payload: { pluginId: string; message: unknown }): void => cb(payload)
    ipcRenderer.on(IPC.PLUGIN_HOST_EVENT, listener)
    return () => ipcRenderer.removeListener(IPC.PLUGIN_HOST_EVENT, listener)
  },
  onPluginLitheAction: (cb: (payload: { pluginId: string; action: string; payload: unknown }) => void) => {
    const listener = (_event: unknown, p: any): void => cb(p)
    ipcRenderer.on('plugin:lithe-action', listener)
    return () => ipcRenderer.removeListener('plugin:lithe-action', listener)
  },
  pluginOpenFolder: () => ipcRenderer.invoke(IPC.PLUGIN_OPEN_FOLDER),

  // Utilities
  removeAllListeners: (channel: string) => ipcRenderer.removeAllListeners(channel)
}

if (process.contextIsolated) {
  try {
    contextBridge.exposeInMainWorld('electron', electronAPI)
    contextBridge.exposeInMainWorld('api', api)
  } catch (error) {
    console.error(error)
  }
} else {
  // @ts-ignore
  window.electron = electronAPI
  // @ts-ignore
  window.api = api
}
