import { ipcMain } from 'electron'
import * as fs from 'fs/promises'
import * as path from 'path'
import { IPC } from '@common/ipc'

const BINARY_EXTENSIONS = new Set([
  'class', 'jar', 'war', 'ear', 'dll', 'exe', 'so', 'dylib', 'o', 'a', 'lib',
  'png', 'jpg', 'jpeg', 'gif', 'webp', 'ico', 'icns', 'bmp', 'tif', 'tiff',
  'pdf', 'zip', 'gz', 'tgz', '7z', 'rar', 'tar', 'xz', 'bz2',
  'woff', 'woff2', 'ttf', 'otf', 'eot',
  'mp3', 'mp4', 'wav', 'avi', 'mov', 'webm', 'mkv',
  'db', 'sqlite', 'bin', 'dat', 'pak', 'pdb', 'ilk', 'obj',
  'pyc', 'pyo', 'wasm', 'node', 'dmg', 'iso', 'img'
])

function looksBinary(buf: Buffer): boolean {
  const sample = buf.subarray(0, Math.min(buf.length, 8192))
  if (sample.includes(0)) return true
  // High ratio of non-text control bytes
  let weird = 0
  for (let i = 0; i < sample.length; i++) {
    const c = sample[i]
    if (c === 9 || c === 10 || c === 13) continue
    if (c < 32 || c === 127) weird++
  }
  return sample.length > 0 && weird / sample.length > 0.05
}

function formatSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
}

export function registerFileHandlers(): void {
  ipcMain.handle(IPC.FILE_READ, async (_e, filePath: string) => {
    const stat = await fs.stat(filePath)
    const ext = path.extname(filePath).slice(1).toLowerCase()
    const isReadOnly = !(stat.mode & 0o200)

    if (BINARY_EXTENSIONS.has(ext)) {
      return {
        content: '',
        binary: true,
        size: stat.size,
        sizeLabel: formatSize(stat.size),
        mtimeMs: stat.mtimeMs,
        isReadOnly
      }
    }

    const buf = await fs.readFile(filePath)
    if (looksBinary(buf)) {
      return {
        content: '',
        binary: true,
        size: stat.size,
        sizeLabel: formatSize(stat.size),
        mtimeMs: stat.mtimeMs,
        isReadOnly
      }
    }

    return {
      content: buf.toString('utf-8'),
      binary: false,
      size: stat.size,
      sizeLabel: formatSize(stat.size),
      mtimeMs: stat.mtimeMs,
      isReadOnly
    }
  })

  ipcMain.handle(IPC.FILE_WRITE, async (_e, filePath: string, content: string) => {
    await fs.mkdir(path.dirname(filePath), { recursive: true })
    await fs.writeFile(filePath, content, 'utf-8')
    const stat = await fs.stat(filePath)
    return { mtimeMs: stat.mtimeMs }
  })

  ipcMain.handle(IPC.FILE_EXISTS, async (_e, filePath: string) => {
    try {
      await fs.access(filePath)
      return true
    } catch {
      return false
    }
  })

  ipcMain.handle(IPC.FILE_STAT, async (_e, filePath: string) => {
    const stat = await fs.stat(filePath)
    return {
      size: stat.size,
      mtimeMs: stat.mtimeMs,
      isDirectory: stat.isDirectory(),
      isFile: stat.isFile()
    }
  })

  ipcMain.handle(IPC.FILE_DELETE, async (_e, filePath: string) => {
    const stat = await fs.stat(filePath)
    if (stat.isDirectory()) {
      await fs.rm(filePath, { recursive: true, force: true })
    } else {
      await fs.unlink(filePath)
    }
  })

  ipcMain.handle(IPC.FILE_RENAME, async (_e, oldPath: string, newPath: string) => {
    await fs.rename(oldPath, newPath)
  })

  ipcMain.handle(
    IPC.FILE_CREATE,
    async (_e, targetPath: string, opts?: { directory?: boolean; content?: string }) => {
      if (opts?.directory) {
        await fs.mkdir(targetPath, { recursive: true })
      } else {
        await fs.mkdir(path.dirname(targetPath), { recursive: true })
        await fs.writeFile(targetPath, opts?.content ?? '', { flag: 'wx' })
      }
      return targetPath
    }
  )

  ipcMain.handle(IPC.FILE_REVEAL, async (_e, targetPath: string) => {
    const { shell } = await import('electron')
    shell.showItemInFolder(targetPath)
  })

  ipcMain.handle(IPC.FILE_PICK_DIRECTORY, async () => {
    const { dialog, BrowserWindow } = await import('electron')
    const win = BrowserWindow.getFocusedWindow()
    const result = win
      ? await dialog.showOpenDialog(win, { properties: ['openDirectory', 'createDirectory'] })
      : await dialog.showOpenDialog({ properties: ['openDirectory', 'createDirectory'] })
    if (result.canceled || !result.filePaths[0]) return null
    return result.filePaths[0]
  })
}
