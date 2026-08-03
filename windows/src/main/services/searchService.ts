import { ipcMain } from 'electron'
import * as fs from 'fs/promises'
import * as path from 'path'
import { IPC } from '@common/ipc'
import type { SearchResult } from '@common/types'

const SKIP_DIRS = new Set([
  '.git', 'node_modules', 'target', 'build', 'dist', 'out', '.gradle', '.idea', '.vscode'
])

const TEXT_EXT = new Set([
  '.java', '.kt', '.kts', '.xml', '.json', '.yml', '.yaml', '.properties', '.md', '.txt',
  '.ts', '.tsx', '.js', '.jsx', '.css', '.scss', '.html', '.gradle', '.swift', '.py',
  '.go', '.rs', '.c', '.cpp', '.h', '.sh', '.bat', '.ps1', '.toml', '.sql', '.ini', '.cfg'
])

const MAX_FILE_SIZE = 2 * 1024 * 1024
const MAX_RESULTS = 2000

interface SearchOptions {
  query: string
  caseSensitive?: boolean
  wholeWord?: boolean
  regex?: boolean
  includeFileNames?: boolean
}

async function* walkFiles(dir: string, depth = 0): AsyncGenerator<string> {
  if (depth > 20) return
  let entries: import('fs').Dirent[]
  try {
    entries = await fs.readdir(dir, { withFileTypes: true })
  } catch {
    return
  }
  for (const entry of entries) {
    const full = path.join(dir, entry.name)
    if (entry.isDirectory()) {
      if (SKIP_DIRS.has(entry.name) || entry.name.startsWith('.')) continue
      yield* walkFiles(full, depth + 1)
    } else if (entry.isFile()) {
      yield full
    }
  }
}

function buildMatcher(opts: SearchOptions): RegExp {
  let source = opts.regex ? opts.query : escapeRegExp(opts.query)
  if (opts.wholeWord) source = `\\b${source}\\b`
  const flags = opts.caseSensitive ? 'g' : 'gi'
  return new RegExp(source, flags)
}

function escapeRegExp(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}

/** Java symbol extraction — mirrors JavaEditorStructureService.swift's regex approach. */
const JAVA_TYPE_RE = /^\s*(?:public|private|protected)?\s*(?:static\s+|final\s+|abstract\s+)*(class|interface|enum|record)\s+(\w+)/
const JAVA_METHOD_RE = /^\s*(?:public|private|protected)\s+(?:static\s+|final\s+|synchronized\s+|abstract\s+|native\s+)*[\w<>\[\],\s?.]+\s+(\w+)\s*\(/

export function registerSearchHandlers(): void {
  ipcMain.handle(IPC.SEARCH_PROJECT, async (_e, root: string, opts: SearchOptions) => {
    const results: SearchResult[] = []
    if (!opts.query) return results

    const matcher = buildMatcher(opts)
    const nameMatcher = buildMatcher({ ...opts, regex: false })

    for await (const filePath of walkFiles(root)) {
      if (results.length >= MAX_RESULTS) break

      const base = path.basename(filePath)
      const ext = path.extname(filePath).toLowerCase()

      // File-name matches
      if (opts.includeFileNames !== false) {
        nameMatcher.lastIndex = 0
        if (nameMatcher.test(base)) {
          results.push({ kind: 'file', path: filePath, preview: path.relative(root, filePath) })
        }
      }

      if (!TEXT_EXT.has(ext)) continue

      let stat: import('fs').Stats
      try {
        stat = await fs.stat(filePath)
      } catch {
        continue
      }
      if (stat.size > MAX_FILE_SIZE) continue

      let text: string
      try {
        text = await fs.readFile(filePath, 'utf-8')
      } catch {
        continue
      }

      const lines = text.split(/\r?\n/)
      for (let i = 0; i < lines.length; i++) {
        if (results.length >= MAX_RESULTS) break
        const line = lines[i]

        matcher.lastIndex = 0
        if (matcher.test(line)) {
          results.push({
            kind: 'content',
            path: filePath,
            line: i + 1,
            preview: line.trim().slice(0, 200)
          })
        }

        // Java type / symbol matches for Search Everywhere parity
        if (ext === '.java') {
          const typeMatch = JAVA_TYPE_RE.exec(line)
          if (typeMatch) {
            nameMatcher.lastIndex = 0
            if (nameMatcher.test(typeMatch[2])) {
              results.push({
                kind: 'type',
                path: filePath,
                line: i + 1,
                preview: line.trim(),
                symbolName: typeMatch[2]
              })
            }
            continue
          }
          const methodMatch = JAVA_METHOD_RE.exec(line)
          if (methodMatch) {
            nameMatcher.lastIndex = 0
            if (nameMatcher.test(methodMatch[1])) {
              results.push({
                kind: 'symbol',
                path: filePath,
                line: i + 1,
                preview: line.trim(),
                symbolName: methodMatch[1]
              })
            }
          }
        }
      }
    }

    return results
  })

  ipcMain.handle(
    IPC.SEARCH_REPLACE,
    async (_e, root: string, opts: SearchOptions, replacement: string, targetFiles?: string[]) => {
      const matcher = buildMatcher(opts)
      let filesChanged = 0
      let replacements = 0

      const candidates: string[] = []
      if (targetFiles && targetFiles.length > 0) {
        candidates.push(...targetFiles)
      } else {
        for await (const f of walkFiles(root)) {
          if (TEXT_EXT.has(path.extname(f).toLowerCase())) candidates.push(f)
        }
      }

      for (const filePath of candidates) {
        let text: string
        try {
          text = await fs.readFile(filePath, 'utf-8')
        } catch {
          continue
        }
        matcher.lastIndex = 0
        const matches = text.match(matcher)
        if (!matches || matches.length === 0) continue
        matcher.lastIndex = 0
        const updated = text.replace(matcher, replacement)
        await fs.writeFile(filePath, updated, 'utf-8')
        filesChanged += 1
        replacements += matches.length
      }

      return { filesChanged, replacements }
    }
  )
}
