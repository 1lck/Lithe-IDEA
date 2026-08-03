import { ipcMain, app } from 'electron'
import * as fs from 'fs/promises'
import * as path from 'path'
import { IPC } from '@common/ipc'
import type { LocalHistoryEntry, AppSettings } from '@common/types'

const historyDir = (): string => path.join(app.getPath('userData'), 'local-history')
const settingsPath = (): string => path.join(app.getPath('userData'), 'settings.json')

const DEFAULT_SETTINGS: AppSettings = {
  language: 'en',
  editorFontSize: 13,
  tabWidth: 4,
  showCodeVision: true,
  autoSave: false,
  autoSaveDelay: 1.5,
  terminalShell: 'system',
  hiddenDirectories: ['.git', 'node_modules', 'target', 'build', 'dist', 'out', '.gradle'],
  hiddenFilePatterns: ['*.class', '*.jar', '.DS_Store', 'Thumbs.db']
}

export function registerLocalHistoryHandlers(): void {
  ipcMain.handle(IPC.LOCAL_HISTORY_SAVE, async (_e, filePath: string, content: string) => {
    const dir = historyDir()
    await fs.mkdir(dir, { recursive: true })
    const entry: LocalHistoryEntry = {
      timestamp: Date.now(),
      path: filePath,
      content
    }
    const fileName = `${Date.now()}-${path.basename(filePath).replace(/[^a-zA-Z0-9.-]/g, '_')}.json`
    await fs.writeFile(path.join(dir, fileName), JSON.stringify(entry), 'utf-8')
  })

  ipcMain.handle(IPC.LOCAL_HISTORY_LIST, async (_e, filePath: string) => {
    const dir = historyDir()
    try {
      const files = await fs.readdir(dir)
      const entries: { timestamp: number; fileName: string }[] = []
      for (const f of files) {
        try {
          const raw = await fs.readFile(path.join(dir, f), 'utf-8')
          const entry: LocalHistoryEntry = JSON.parse(raw)
          if (entry.path === filePath) {
            entries.push({ timestamp: entry.timestamp, fileName: f })
          }
        } catch { /* skip malformed */ }
      }
      entries.sort((a, b) => b.timestamp - a.timestamp)
      return entries.slice(0, 100)
    } catch {
      return []
    }
  })

  ipcMain.handle(IPC.LOCAL_HISTORY_GET, async (_e, fileName: string) => {
    const dir = historyDir()
    const raw = await fs.readFile(path.join(dir, fileName), 'utf-8')
    return JSON.parse(raw) as LocalHistoryEntry
  })

  ipcMain.handle(IPC.LOCAL_HISTORY_RESTORE, async (_e, historyFileName: string) => {
    const dir = historyDir()
    const raw = await fs.readFile(path.join(dir, historyFileName), 'utf-8')
    const entry = JSON.parse(raw) as LocalHistoryEntry
    // Snapshot current disk content before overwrite
    try {
      const current = await fs.readFile(entry.path, 'utf-8')
      if (current !== entry.content) {
        const snap: LocalHistoryEntry = {
          timestamp: Date.now(),
          path: entry.path,
          content: current
        }
        const snapName = `${Date.now()}-pre-restore-${path.basename(entry.path).replace(/[^a-zA-Z0-9.-]/g, '_')}.json`
        await fs.writeFile(path.join(dir, snapName), JSON.stringify(snap), 'utf-8')
      }
    } catch {
      /* file may not exist */
    }
    await fs.mkdir(path.dirname(entry.path), { recursive: true })
    await fs.writeFile(entry.path, entry.content, 'utf-8')
    return entry
  })
}

export function registerSettingsHandlers(): void {
  ipcMain.handle(IPC.SETTINGS_GET, async () => {
    try {
      const raw = await fs.readFile(settingsPath(), 'utf-8')
      return { ...DEFAULT_SETTINGS, ...JSON.parse(raw) }
    } catch {
      return { ...DEFAULT_SETTINGS }
    }
  })

  ipcMain.handle(IPC.SETTINGS_SET, async (_e, partial: Partial<AppSettings>) => {
    let current: AppSettings
    try {
      const raw = await fs.readFile(settingsPath(), 'utf-8')
      current = { ...DEFAULT_SETTINGS, ...JSON.parse(raw) }
    } catch {
      current = { ...DEFAULT_SETTINGS }
    }
    const updated = { ...current, ...partial }
    await fs.mkdir(path.dirname(settingsPath()), { recursive: true })
    await fs.writeFile(settingsPath(), JSON.stringify(updated, null, 2), 'utf-8')
    return updated
  })
}
