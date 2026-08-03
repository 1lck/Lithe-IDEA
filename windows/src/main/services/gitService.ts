import { ipcMain } from 'electron'
import { IPC } from '@common/ipc'
import { execFile, spawn } from 'child_process'
import { promisify } from 'util'
import * as fs from 'fs/promises'
import * as path from 'path'
import type { GitLogEntry, GitStatus, GitFileChange } from '@common/types'

const execFileAsync = promisify(execFile)

async function isGitRepo(cwd: string): Promise<boolean> {
  try {
    // Walk up looking for .git — matches git's own discovery rules
    let dir = path.resolve(cwd)
    while (true) {
      try {
        const stat = await fs.stat(path.join(dir, '.git'))
        if (stat.isDirectory() || stat.isFile()) return true
      } catch { /* not here */ }
      const parent = path.dirname(dir)
      if (parent === dir) return false
      dir = parent
    }
  } catch {
    return false
  }
}

async function git(cwd: string, ...args: string[]): Promise<string> {
  const { stdout } = await execFileAsync('git', args, { cwd, maxBuffer: 10 * 1024 * 1024 })
  return stdout.trim()
}

function parseStatus(raw: string): GitStatus {
  const staged: GitFileChange[] = []
  const unstaged: GitFileChange[] = []
  const untracked: string[] = []
  let branch = ''

  for (const line of raw.split('\n')) {
    if (line.startsWith('## ')) {
      branch = line.slice(3).split('...')[0]
      continue
    }
    const x = line[0]
    const y = line[1]
    const file = line.slice(3)
    if (x === '?' && y === '?') {
      untracked.push(file)
    } else {
      if (x !== ' ' && x !== '?') staged.push({ path: file, status: statusChar(x) })
      if (y !== ' ' && y !== '?') unstaged.push({ path: file, status: statusChar(y) })
    }
  }
  return { branch, staged, unstaged, untracked }
}

function statusChar(c: string): GitFileChange['status'] {
  switch (c) {
    case 'M': return 'modified'
    case 'A': return 'added'
    case 'D': return 'deleted'
    case 'R': return 'renamed'
    case 'C': return 'copied'
    default: return 'modified'
  }
}

export function registerGitHandlers(): void {
  ipcMain.handle(IPC.GIT_STATUS, async (_e, cwd: string) => {
    if (!(await isGitRepo(cwd))) return null
    const raw = await git(cwd, 'status', '--porcelain=v1', '-b')
    return parseStatus(raw)
  })

  ipcMain.handle(IPC.GIT_LOG, async (_e, cwd: string, max = 500) => {
    if (!(await isGitRepo(cwd))) return []
    const format = '%H%n%h%n%an%n%ae%n%aI%n%s%n%P%n%D%n---'
    const raw = await git(cwd, 'log', `--max-count=${max}`, `--format=${format}`, '--all')
    const entries: GitLogEntry[] = []
    const blocks = raw.split('\n---\n')
    for (const block of blocks) {
      const lines = block.split('\n')
      if (lines.length < 7) continue
      entries.push({
        hash: lines[0],
        shortHash: lines[1],
        author: lines[2],
        email: lines[3],
        date: lines[4],
        message: lines[5],
        parents: lines[6] ? lines[6].split(' ') : [],
        refs: lines[7] ? lines[7].split(', ').filter(Boolean) : []
      })
    }
    return entries
  })

  ipcMain.handle(IPC.GIT_DIFF, async (_e, cwd: string, filePath?: string, staged?: boolean) => {
    if (!(await isGitRepo(cwd))) return ''
    const args = ['diff']
    if (staged) args.push('--cached')
    if (filePath) args.push('--', filePath)
    return git(cwd, ...args)
  })

  ipcMain.handle(IPC.GIT_BRANCH_LIST, async (_e, cwd: string) => {
    if (!(await isGitRepo(cwd))) return []
    const raw = await git(cwd, 'branch', '-a', '--format=%(refname:short)|||%(objectname:short)|||%(HEAD)')
    return raw.split('\n').filter(Boolean).map((line) => {
      const [name, hash, isCurrent] = line.split('|||')
      return { name, hash, isCurrent: isCurrent === '*' }
    })
  })

  ipcMain.handle(IPC.GIT_BRANCH_SWITCH, async (_e, cwd: string, branchName: string) => {
    await git(cwd, 'checkout', branchName)
  })

  ipcMain.handle(
    IPC.GIT_BRANCH_CREATE,
    async (_e, cwd: string, name: string, checkout = true) => {
      if (checkout) await git(cwd, 'checkout', '-b', name)
      else await git(cwd, 'branch', name)
    }
  )

  ipcMain.handle(IPC.GIT_BRANCH_DELETE, async (_e, cwd: string, name: string, force = false) => {
    await git(cwd, 'branch', force ? '-D' : '-d', name)
  })

  ipcMain.handle(IPC.GIT_COMMIT, async (_e, cwd: string, message: string, amend = false) => {
    const args = ['commit', '-m', message]
    if (amend) args.splice(1, 0, '--amend')
    await git(cwd, ...args)
  })

  ipcMain.handle(IPC.GIT_STAGE, async (_e, cwd: string, files: string[]) => {
    await git(cwd, 'add', '--', ...files)
  })

  ipcMain.handle(IPC.GIT_UNSTAGE, async (_e, cwd: string, files: string[]) => {
    await git(cwd, 'reset', 'HEAD', '--', ...files)
  })

  ipcMain.handle(IPC.GIT_DISCARD, async (_e, cwd: string, files: string[]) => {
    if (!files.length) return
    // Separate untracked vs tracked — restore tracked, remove untracked
    const status = parseStatus(await git(cwd, 'status', '--porcelain=v1', '-b'))
    const untracked = new Set(status.untracked)
    const tracked = files.filter((f) => !untracked.has(f))
    const gone = files.filter((f) => untracked.has(f))
    if (tracked.length) await git(cwd, 'checkout', '--', ...tracked)
    for (const f of gone) {
      const full = path.join(cwd, f)
      try {
        const st = await fs.stat(full)
        if (st.isDirectory()) await fs.rm(full, { recursive: true, force: true })
        else await fs.unlink(full)
      } catch {
        /* already gone */
      }
    }
  })

  ipcMain.handle(IPC.GIT_STASH_LIST, async (_e, cwd: string) => {
    if (!(await isGitRepo(cwd))) return []
    const raw = await git(cwd, 'stash', 'list', '--format=%gd|||%gs|||%aI')
    if (!raw) return []
    return raw.split('\n').filter(Boolean).map((line, index) => {
      const [ref, message, date] = line.split('|||')
      return { index, ref: ref || `stash@{${index}}`, message: message || '', date: date || '' }
    })
  })

  ipcMain.handle(IPC.GIT_STASH_SAVE, async (_e, cwd: string, message?: string) => {
    const args = ['stash', 'push', '-u']
    if (message?.trim()) args.push('-m', message.trim())
    await git(cwd, ...args)
  })

  ipcMain.handle(IPC.GIT_STASH_APPLY, async (_e, cwd: string, index = 0, pop = false) => {
    await git(cwd, 'stash', pop ? 'pop' : 'apply', `stash@{${index}}`)
  })

  ipcMain.handle(IPC.GIT_STASH_DROP, async (_e, cwd: string, index = 0) => {
    await git(cwd, 'stash', 'drop', `stash@{${index}}`)
  })

  ipcMain.handle(IPC.GIT_CLONE, async (event, url: string, dest: string) => {
    return new Promise<void>((resolve, reject) => {
      const proc = spawn('git', ['clone', '--progress', url, dest])
      proc.stderr?.on('data', (data) => {
        event.sender.send('git:clone-progress', data.toString())
      })
      proc.on('close', (code) => (code === 0 ? resolve() : reject(new Error(`git clone failed: ${code}`))))
    })
  })
}
