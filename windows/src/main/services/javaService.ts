import { ipcMain } from 'electron'
import { IPC } from '@common/ipc'
import { execFile, spawn, ChildProcess } from 'child_process'
import { promisify } from 'util'
import * as path from 'path'
import * as fs from 'fs/promises'
import type { JdkInfo } from '@common/types'

const execFileAsync = promisify(execFile)

async function discoverJdks(): Promise<JdkInfo[]> {
  const results: JdkInfo[] = []
  const seen = new Set<string>()

  const addJdk = async (dir: string): Promise<void> => {
    const normalized = path.normalize(dir)
    if (seen.has(normalized)) return
    try {
      const javaBin = path.join(normalized, 'bin', 'java.exe')
      await fs.access(javaBin)
      seen.add(normalized)
      try {
        const { stdout } = await execFileAsync(javaBin, ['-version'], { timeout: 5000 })
        // java -version outputs to stderr on older JDKs, but execFile captures stderr via {stdio}
        const version = stdout || ''
        results.push({ path: normalized, version: version.split('\n')[0] || 'unknown', vendor: 'unknown' })
      } catch (e: any) {
        // java -version writes to stderr
        const version = e?.stderr?.split('\n')[0] || 'unknown'
        results.push({ path: normalized, version, vendor: 'unknown' })
      }
    } catch {
      // not a valid JDK
    }
  }

  // 1. JAVA_HOME
  if (process.env.JAVA_HOME) await addJdk(process.env.JAVA_HOME)

  // 2. Common Windows JDK locations
  const roots = [
    'C:\\Program Files\\Java',
    'C:\\Program Files\\Eclipse Adoptium',
    'C:\\Program Files\\Microsoft',
    'C:\\Program Files\\Amazon Corretto',
    'C:\\Program Files\\Zulu',
    path.join(process.env.LOCALAPPDATA || '', 'Programs', 'Eclipse Adoptium')
  ]

  for (const root of roots) {
    try {
      const entries = await fs.readdir(root, { withFileTypes: true })
      for (const entry of entries) {
        if (entry.isDirectory() && /jdk|jre/i.test(entry.name)) {
          await addJdk(path.join(root, entry.name))
        }
      }
    } catch {
      // directory doesn't exist
    }
  }

  return results
}

async function findMaven(projectDir: string): Promise<string | null> {
  // 1. mvnw.cmd in project
  const mvnw = path.join(projectDir, 'mvnw.cmd')
  try {
    await fs.access(mvnw)
    return mvnw
  } catch { /* ignore */ }

  // 2. MAVEN_HOME
  if (process.env.MAVEN_HOME) {
    const bin = path.join(process.env.MAVEN_HOME, 'bin', 'mvn.cmd')
    try {
      await fs.access(bin)
      return bin
    } catch { /* ignore */ }
  }

  // 3. PATH - try to find mvn
  try {
    const { stdout } = await execFileAsync('where', ['mvn'], { timeout: 5000 })
    const firstLine = stdout.trim().split('\n')[0]
    if (firstLine) return firstLine
  } catch { /* ignore */ }

  return null
}

const runningProcesses = new Map<string, ChildProcess>()

export function registerJavaHandlers(): void {
  ipcMain.handle(IPC.JAVA_DISCOVER_JDKS, async () => {
    return discoverJdks()
  })

  ipcMain.handle(IPC.MAVEN_DISCOVER, async (_e, projectDir: string) => {
    return findMaven(projectDir)
  })

  ipcMain.handle(IPC.JAVA_RUN, async (event, id: string, config: {
    jdkPath: string
    mainClass: string
    classpath?: string
    args?: string
    vmOptions?: string
    cwd: string
  }) => {
    const java = path.join(config.jdkPath, 'bin', 'java.exe')
    const cmdArgs: string[] = []
    if (config.vmOptions) cmdArgs.push(...config.vmOptions.split(/\s+/))
    if (config.classpath) cmdArgs.push('-cp', config.classpath)
    cmdArgs.push(config.mainClass)
    if (config.args) cmdArgs.push(...config.args.split(/\s+/))

    const proc = spawn(java, cmdArgs, { cwd: config.cwd, env: process.env })
    runningProcesses.set(id, proc)

    proc.stdout?.on('data', (data) => event.sender.send('java:output', { id, data: data.toString() }))
    proc.stderr?.on('data', (data) => event.sender.send('java:output', { id, data: data.toString() }))
    proc.on('close', (code) => {
      event.sender.send('java:exit', { id, code })
      runningProcesses.delete(id)
    })
  })

  ipcMain.handle(IPC.MAVEN_RUN, async (event, id: string, config: {
    mavenPath: string
    goals: string[]
    cwd: string
    jdkPath?: string
  }) => {
    const env = { ...process.env }
    if (config.jdkPath) env.JAVA_HOME = config.jdkPath

    const proc = spawn(config.mavenPath, config.goals, { cwd: config.cwd, env, shell: true })
    runningProcesses.set(id, proc)

    proc.stdout?.on('data', (data) => event.sender.send('java:output', { id, data: data.toString() }))
    proc.stderr?.on('data', (data) => event.sender.send('java:output', { id, data: data.toString() }))
    proc.on('close', (code) => {
      event.sender.send('java:exit', { id, code })
      runningProcesses.delete(id)
    })
  })

  ipcMain.handle(IPC.MAVEN_SCAN_MODULES, async (_e, projectDir: string) => {
    // Simple scan: find all pom.xml files
    const modules: { name: string; path: string }[] = []
    async function scan(dir: string, depth = 0): Promise<void> {
      if (depth > 5) return
      try {
        const entries = await fs.readdir(dir, { withFileTypes: true })
        for (const e of entries) {
          if (e.name === 'pom.xml' && e.isFile()) {
            modules.push({ name: path.basename(dir), path: dir })
          }
          if (e.isDirectory() && !e.name.startsWith('.') && e.name !== 'target' && e.name !== 'node_modules') {
            await scan(path.join(dir, e.name), depth + 1)
          }
        }
      } catch { /* ignore */ }
    }
    await scan(projectDir)
    return modules
  })
}
