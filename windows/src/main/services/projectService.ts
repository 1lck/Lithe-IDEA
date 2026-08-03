import { ipcMain, dialog, app, BrowserWindow } from 'electron'
import * as fs from 'fs/promises'
import * as path from 'path'
import chokidar, { FSWatcher } from 'chokidar'
import { IPC } from '@common/ipc'
import type { FileNode, RecentProject } from '@common/types'

const DEFAULT_HIDDEN_DIRS = new Set([
  '.git',
  'node_modules',
  '.idea',
  '.vscode',
  'target',
  'build',
  'dist',
  'out',
  '.gradle'
])

async function scanDirectory(
  dirPath: string,
  hiddenDirs: Set<string>,
  depth = 0,
  maxDepth = 12
): Promise<FileNode> {
  const name = path.basename(dirPath)
  const node: FileNode = {
    path: dirPath,
    name,
    isDirectory: true,
    children: []
  }

  if (depth >= maxDepth) return node

  let entries: import('fs').Dirent[]
  try {
    entries = await fs.readdir(dirPath, { withFileTypes: true })
  } catch {
    return node
  }

  const children: FileNode[] = []
  for (const entry of entries) {
    const full = path.join(dirPath, entry.name)
    if (entry.isDirectory()) {
      if (hiddenDirs.has(entry.name) || entry.name.startsWith('.')) continue
      children.push(await scanDirectory(full, hiddenDirs, depth + 1, maxDepth))
    } else if (entry.isFile()) {
      children.push({
        path: full,
        name: entry.name,
        isDirectory: false
      })
    }
  }
  // Sort: directories first, then alphabetical
  children.sort((a, b) => {
    if (a.isDirectory !== b.isDirectory) return a.isDirectory ? -1 : 1
    return a.name.localeCompare(b.name)
  })
  node.children = children
  return node
}

const watchers = new Map<string, FSWatcher>()

const recentPath = path.join(app.getPath('userData'), 'recent-projects.json')

async function loadRecent(): Promise<RecentProject[]> {
  try {
    const text = await fs.readFile(recentPath, 'utf-8')
    return JSON.parse(text) as RecentProject[]
  } catch {
    return []
  }
}

async function saveRecent(list: RecentProject[]): Promise<void> {
  await fs.mkdir(path.dirname(recentPath), { recursive: true })
  await fs.writeFile(recentPath, JSON.stringify(list, null, 2), 'utf-8')
}

export function registerProjectHandlers(): void {
  ipcMain.handle(IPC.PROJECT_OPEN_DIALOG, async () => {
    const win = BrowserWindow.getFocusedWindow()
    const result = await dialog.showOpenDialog(win!, {
      properties: ['openDirectory']
    })
    if (result.canceled || result.filePaths.length === 0) return null
    return result.filePaths[0]
  })

  ipcMain.handle(
    IPC.PROJECT_SCAN,
    async (_e, dirPath: string, hiddenDirs: string[] = []) => {
      const hidden = new Set([...DEFAULT_HIDDEN_DIRS, ...hiddenDirs])
      return scanDirectory(dirPath, hidden)
    }
  )

  ipcMain.handle(IPC.PROJECT_WATCH_START, async (event, dirPath: string, key: string) => {
    stopWatcher(key)
    const watcher = chokidar.watch(dirPath, {
      ignored: (p) => {
        const base = path.basename(p)
        return DEFAULT_HIDDEN_DIRS.has(base) || base.startsWith('.git')
      },
      ignoreInitial: true,
      persistent: true,
      awaitWriteFinish: { stabilityThreshold: 200, pollInterval: 50 }
    })
    watcher.on('all', (evt, changedPath) => {
      event.sender.send('project:watch-event', { key, event: evt, path: changedPath })
    })
    watchers.set(key, watcher)
  })

  ipcMain.handle(IPC.PROJECT_WATCH_STOP, async (_e, key: string) => {
    stopWatcher(key)
  })

  ipcMain.handle(IPC.PROJECT_RECENT_LIST, async () => {
    return loadRecent()
  })

  ipcMain.handle(IPC.PROJECT_RECENT_ADD, async (_e, dirPath: string) => {
    const list = await loadRecent()
    const filtered = list.filter((p) => p.path !== dirPath)
    filtered.unshift({
      path: dirPath,
      name: path.basename(dirPath),
      lastOpened: Date.now()
    })
    const truncated = filtered.slice(0, 30)
    await saveRecent(truncated)
    return truncated
  })

  ipcMain.handle(IPC.PROJECT_RECENT_REMOVE, async (_e, dirPath: string) => {
    const list = await loadRecent()
    const filtered = list.filter((p) => p.path !== dirPath)
    await saveRecent(filtered)
    return filtered
  })
}

function stopWatcher(key: string): void {
  const existing = watchers.get(key)
  if (existing) {
    existing.close().catch(() => undefined)
    watchers.delete(key)
  }
}
