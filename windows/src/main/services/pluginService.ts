import { app, dialog, ipcMain, shell, BrowserWindow } from 'electron'
import * as fs from 'fs'
import * as fsp from 'fs/promises'
import * as path from 'path'
import * as https from 'https'
import * as http from 'http'
import { execFile } from 'child_process'
import { promisify } from 'util'
import { IPC } from '@common/ipc'
import type {
  MarketplaceExportFormat,
  MarketplaceExportResult,
  MarketplaceInstallOptions,
  MarketplacePlugin,
  MarketplaceVersion,
  PluginCommandContribution,
  PluginContributions,
  PluginInfo,
  PluginKind,
  PluginThemeContribution,
  PluginViewContribution,
  PluginViewTitleButton
} from '@common/types'
import { detectVscodeWebviewAssets, pluginSidebarUrl } from './pluginProtocol'
import {
  ensurePluginStaticServer,
  pluginWebviewHttpUrl,
  updatePluginStaticRoots
} from './pluginStaticServer'
import { executeExtensionCommand, getExtensionHost, postToExtensionHost, startExtensionHost } from './extensionHost'

const execFileAsync = promisify(execFile)

interface PluginState {
  enabled: Record<string, boolean>
}

const emptyContrib = (): PluginContributions => ({
  themes: [],
  commands: [],
  snippets: [],
  languages: [],
  views: []
})

async function resolveIconDataUrl(absPath: string): Promise<string | undefined> {
  try {
    if (!(await pathExists(absPath))) return undefined
    const ext = path.extname(absPath).toLowerCase()
    const buf = await fsp.readFile(absPath)
    const b64 = buf.toString('base64')
    if (ext === '.svg') return `data:image/svg+xml;base64,${b64}`
    if (ext === '.png') return `data:image/png;base64,${b64}`
    if (ext === '.jpg' || ext === '.jpeg') return `data:image/jpeg;base64,${b64}`
    if (ext === '.gif') return `data:image/gif;base64,${b64}`
    if (ext === '.webp') return `data:image/webp;base64,${b64}`
  } catch {
    /* ignore */
  }
  return undefined
}

async function hydrateViewIcons(root: string, views: PluginViewContribution[]): Promise<void> {
  for (const v of views) {
    if (v.iconDataUrl || !v.iconPath) continue
    const abs = path.isAbsolute(v.iconPath) ? v.iconPath : path.join(root, v.iconPath)
    v.iconPath = abs
    v.iconDataUrl = await resolveIconDataUrl(abs)
  }
}

/**
 * Parse `contributes.menus["view/title"]` + `contributes.commands` into the
 * toolbar buttons VS Code would render in a view's header (Kilo Code's
 * settings gear, history, marketplace, profile, +). These are attached to the
 * matching activity-bar view so the renderer can draw them.
 */
async function attachTitleButtons(
  root: string,
  contributes: PluginContributions,
  rawContributes: any,
  nls: Record<string, string>,
  pluginName: string
): Promise<void> {
  const menus = rawContributes?.menus?.['view/title']
  if (!Array.isArray(menus) || !menus.length) return

  const commands: any[] = Array.isArray(rawContributes?.commands) ? rawContributes.commands : []
  const cmdById = new Map<string, any>()
  for (const c of commands) if (c?.command) cmdById.set(String(c.command), c)

  // Group buttons by the view they target (when == "view == <id>")
  for (const view of contributes.views) {
    const buttons: PluginViewTitleButton[] = []
    for (const item of menus) {
      if (!item?.command) continue
      const when = String(item.when || '')
      // Only include if the menu targets this view (or has no view constraint).
      // Skip entries explicitly disabled via `false && ...`.
      if (/^\s*false\b/.test(when)) continue
      if (when && when.includes('view ==') && !when.includes(view.id)) continue
      if (when && when.includes('view ==') === false && when.includes('view') ) {
        // some use `activeViewlet` etc — skip unknown constraints for safety
      }

      const cmd = cmdById.get(String(item.command))
      const title = resolveNls(cmd?.title || item.command, nls, String(item.command))
      const iconRaw = cmd?.icon
      let codicon: string | undefined
      let iconDataUrl: string | undefined
      if (typeof iconRaw === 'string') {
        const m = iconRaw.match(/^\$\(([^)]+)\)$/)
        if (m) codicon = m[1]
        else iconDataUrl = await resolveIconDataUrl(path.isAbsolute(iconRaw) ? iconRaw : path.join(root, iconRaw))
      } else if (iconRaw && typeof iconRaw === 'object') {
        // { light, dark } — prefer dark
        const p = iconRaw.dark || iconRaw.light
        if (typeof p === 'string') {
          iconDataUrl = await resolveIconDataUrl(path.isAbsolute(p) ? p : path.join(root, p))
        }
      }

      const groupMatch = String(item.group || '').match(/@(\d+)/)
      buttons.push({
        command: String(item.command),
        title,
        codicon,
        iconDataUrl,
        order: groupMatch ? Number(groupMatch[1]) : 999
      })
    }
    if (buttons.length) {
      buttons.sort((a, b) => a.order - b.order)
      view.titleButtons = buttons
    }
  }
  void pluginName
}

/** Load VS Code package.nls.json (+ locale overlay). Keys are without % wrapping. */
async function loadVscodeNls(root: string): Promise<Record<string, string>> {
  const base = (await readJson<Record<string, string>>(path.join(root, 'package.nls.json'))) || {}
  const locale = (app.getLocale?.() || Intl.DateTimeFormat().resolvedOptions().locale || 'en').replace(
    /_/g,
    '-'
  )
  const lang = locale.split('-')[0]?.toLowerCase() || 'en'
  const region = locale.split('-')[1]?.toUpperCase() || ''

  const candidates: string[] = []
  if (lang === 'zh') {
    if (region === 'TW' || region === 'HK' || region === 'MO') {
      candidates.push('package.nls.zh-TW.json', 'package.nls.zh-CN.json')
    } else {
      candidates.push('package.nls.zh-CN.json', 'package.nls.zh-TW.json')
    }
  } else {
    if (region) candidates.push(`package.nls.${lang}-${region}.json`)
    candidates.push(`package.nls.${lang}.json`)
  }

  let overlay: Record<string, string> | null = null
  for (const file of candidates) {
    overlay = await readJson<Record<string, string>>(path.join(root, file))
    if (overlay) break
  }

  return overlay ? { ...base, ...overlay } : base
}

/** Resolve `%key%` placeholders using package.nls dictionaries. */
function resolveNls(raw: unknown, nls: Record<string, string>, fallback = ''): string {
  if (raw == null) return fallback
  const text = String(raw)
  if (!text.includes('%')) return text || fallback
  const resolved = text.replace(/%([^%]+)%/g, (_m, key: string) => {
    const hit = nls[key]
    return hit != null && hit !== '' ? hit : _m
  })
  // If still a bare %key%, fall back
  if (/^%[^%]+%$/.test(resolved.trim())) return fallback || resolved
  return resolved || fallback
}

function pluginsRoot(): string {
  return path.join(app.getPath('userData'), 'plugins')
}

function installedRoot(): string {
  return path.join(pluginsRoot(), 'installed')
}

function statePath(): string {
  return path.join(pluginsRoot(), 'state.json')
}

async function ensureDirs(): Promise<void> {
  await fsp.mkdir(installedRoot(), { recursive: true })
}

async function loadState(): Promise<PluginState> {
  try {
    const raw = await fsp.readFile(statePath(), 'utf8')
    const parsed = JSON.parse(raw) as PluginState
    return { enabled: parsed.enabled || {} }
  } catch {
    return { enabled: {} }
  }
}

async function saveState(state: PluginState): Promise<void> {
  await ensureDirs()
  await fsp.writeFile(statePath(), JSON.stringify(state, null, 2), 'utf8')
}

function safeId(raw: string): string {
  return raw.replace(/[^a-zA-Z0-9._-]+/g, '-').replace(/^-+|-+$/g, '') || `plugin-${Date.now()}`
}

async function pathExists(p: string): Promise<boolean> {
  try {
    await fsp.access(p)
    return true
  } catch {
    return false
  }
}

async function readJson<T>(file: string): Promise<T | null> {
  try {
    return JSON.parse(await fsp.readFile(file, 'utf8')) as T
  } catch {
    return null
  }
}

function extractXmlAttr(tag: string, attr: string): string | undefined {
  const re = new RegExp(`${attr}\\s*=\\s*"([^"]*)"`, 'i')
  const m = tag.match(re)
  return m?.[1]
}

function extractXmlText(xml: string, tag: string): string | undefined {
  const re = new RegExp(`<${tag}[^>]*>([\\s\\S]*?)</${tag}>`, 'i')
  const m = xml.match(re)
  return m?.[1]?.replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, '$1').trim()
}

async function findFileUp(dir: string, names: string[], maxDepth = 4): Promise<string | null> {
  const queue: { d: string; depth: number }[] = [{ d: dir, depth: 0 }]
  while (queue.length) {
    const { d, depth } = queue.shift()!
    for (const name of names) {
      const candidate = path.join(d, name)
      if (await pathExists(candidate)) return candidate
    }
    if (depth >= maxDepth) continue
    let entries: fs.Dirent[]
    try {
      entries = await fsp.readdir(d, { withFileTypes: true })
    } catch {
      continue
    }
    for (const e of entries) {
      if (e.isDirectory() && e.name !== 'node_modules' && !e.name.startsWith('.')) {
        queue.push({ d: path.join(d, e.name), depth: depth + 1 })
      }
    }
  }
  return null
}

async function parseVscodeExtension(root: string): Promise<Omit<PluginInfo, 'enabled'> | null> {
  let pkgPath = path.join(root, 'package.json')
  if (!(await pathExists(pkgPath))) {
    const nested = path.join(root, 'extension', 'package.json')
    if (await pathExists(nested)) {
      pkgPath = nested
      root = path.join(root, 'extension')
    } else {
      const found = await findFileUp(root, ['package.json'])
      if (!found) return null
      pkgPath = found
      root = path.dirname(found)
    }
  }

  const pkg = await readJson<any>(pkgPath)
  if (!pkg || typeof pkg.name !== 'string') return null

  const nls = await loadVscodeNls(root)
  const publisher = String(pkg.publisher || pkg.author?.name || 'unknown')
  const name = resolveNls(pkg.displayName, nls, String(pkg.name))
  const description = resolveNls(pkg.description, nls, '')
  const id = safeId(`${publisher}.${pkg.name}`)
  const contributes = emptyContrib()
  const c = pkg.contributes || {}

  if (Array.isArray(c.themes)) {
    for (const t of c.themes) {
      if (!t?.path) continue
      contributes.themes.push({
        id: String(t.id || `${id}.theme.${contributes.themes.length}`),
        label: resolveNls(t.label || t.id, nls, 'Theme'),
        path: path.join(root, t.path),
        uiTheme: t.uiTheme
      })
    }
  }

  if (Array.isArray(c.commands)) {
    for (const cmd of c.commands) {
      if (!cmd?.command) continue
      contributes.commands.push({
        id: String(cmd.command),
        title: resolveNls(cmd.title || cmd.command, nls, String(cmd.command)),
        category: cmd.category ? resolveNls(cmd.category, nls) : undefined
      })
    }
  }

  if (Array.isArray(c.snippets)) {
    for (const s of c.snippets) {
      if (!s?.path) continue
      const langs = Array.isArray(s.language) ? s.language : [s.language || 'plaintext']
      for (const language of langs) {
        contributes.snippets.push({ language: String(language), path: path.join(root, s.path) })
      }
    }
  }

  if (Array.isArray(c.languages)) {
    for (const lang of c.languages) {
      if (lang?.id) contributes.languages.push(String(lang.id))
    }
  }

  // Activity-bar view containers → sidebar tool-window buttons
  const activityBars = c.viewsContainers?.activitybar
  if (Array.isArray(activityBars)) {
    for (const container of activityBars) {
      if (!container?.id) continue
      const iconRaw = container.icon || container.darkIcon
      const icon =
        typeof iconRaw === 'string' && !iconRaw.startsWith('$') ? String(iconRaw) : undefined
      contributes.views.push({
        id: String(container.id),
        title: resolveNls(container.title || container.id, nls, name),
        iconPath: icon,
        location: 'activitybar'
      })
    }
  }
  const panelContainers = c.viewsContainers?.panel
  if (Array.isArray(panelContainers)) {
    for (const container of panelContainers) {
      if (!container?.id) continue
      const iconRaw = container.icon || container.darkIcon
      contributes.views.push({
        id: String(container.id),
        title: resolveNls(container.title || container.id, nls, name),
        iconPath:
          typeof iconRaw === 'string' && !iconRaw.startsWith('$') ? String(iconRaw) : undefined,
        location: 'panel'
      })
    }
  }

  await hydrateViewIcons(root, contributes.views)

  const hasWebviewUi = detectVscodeWebviewAssets(root)
  if (hasWebviewUi) {
    for (const v of contributes.views) {
      if (v.location === 'activitybar') v.hasWebviewUi = true
    }
  }

  // Attach view/title toolbar buttons (Kilo/Cline: settings, history, marketplace…)
  await attachTitleButtons(root, contributes, c, nls, name)

  const hasRuntime =
    Boolean(pkg.main) || Boolean(pkg.browser) || Boolean(pkg.activationEvents?.length)
  const hasStatic =
    contributes.themes.length +
      contributes.commands.length +
      contributes.snippets.length +
      contributes.views.length >
    0

  // Runtime UI plugins without declared viewsContainers still get a sidebar placeholder
  if (contributes.views.length === 0 && hasRuntime) {
    contributes.views.push({
      id: `${id}.toolwindow`,
      title: name,
      location: 'activitybar',
      synthetic: true
    })
  }

  let compatibility: PluginInfo['compatibility'] = 'metadata'
  let compatibilityNote =
    'VS Code extension APIs are not fully hosted. Static contributions (themes, commands, snippets, views) can apply.'
  if (hasStatic && !hasRuntime) {
    compatibility = 'partial'
    compatibilityNote = 'Static contributions supported (themes / commands / snippets / sidebar views).'
  } else if (hasStatic && hasRuntime) {
    compatibility = 'partial'
    compatibilityNote =
      'Themes, commands, snippets and sidebar buttons apply. Extension host JS (Language Servers, custom webviews) is not executed.'
  } else if (hasRuntime) {
    compatibility = 'metadata'
    compatibilityNote =
      'This extension requires the VS Code Extension Host. A sidebar placeholder is shown; runtime UI is not hosted.'
  }

  return {
    id,
    name,
    version: String(pkg.version || '0.0.0'),
    kind: 'vscode',
    description,
    publisher,
    path: root,
    compatibility,
    compatibilityNote,
    contributes
  }
}

async function parseIdeaPlugin(root: string): Promise<Omit<PluginInfo, 'enabled'> | null> {
  let xmlPath = path.join(root, 'META-INF', 'plugin.xml')
  if (!(await pathExists(xmlPath))) {
    const found = await findFileUp(root, [path.join('META-INF', 'plugin.xml'), 'plugin.xml'])
    if (!found) return null
    xmlPath = found
    if (path.basename(path.dirname(found)) === 'META-INF') {
      root = path.dirname(path.dirname(found))
    } else {
      root = path.dirname(found)
    }
  }

  const xml = await fsp.readFile(xmlPath, 'utf8')
  const ideaTag = xml.match(/<idea-plugin[\s\S]*?>/i)?.[0] || ''
  const id =
    extractXmlText(xml, 'id') ||
    extractXmlAttr(ideaTag, 'id') ||
    extractXmlText(xml, 'name') ||
    `idea-plugin-${Date.now()}`
  const name = extractXmlText(xml, 'name') || id
  const version =
    extractXmlText(xml, 'version') || extractXmlAttr(ideaTag, 'version') || '0.0.0'
  const description = (extractXmlText(xml, 'description') || '')
    .replace(/<[^>]+>/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
  const vendor =
    extractXmlText(xml, 'vendor')?.replace(/<[^>]+>/g, '').trim() ||
    extractXmlAttr(xml.match(/<vendor[^>]*>/i)?.[0] || '', 'email') ||
    'JetBrains'

  const contributes = emptyContrib()

  // Discover .icls color schemes
  const walk = async (dir: string, depth = 0): Promise<void> => {
    if (depth > 5) return
    let entries: fs.Dirent[]
    try {
      entries = await fsp.readdir(dir, { withFileTypes: true })
    } catch {
      return
    }
    for (const e of entries) {
      const full = path.join(dir, e.name)
      if (e.isDirectory()) await walk(full, depth + 1)
      else if (e.name.endsWith('.icls') || e.name.endsWith('.xml')) {
        if (e.name.toLowerCase().includes('color') || e.name.endsWith('.icls')) {
          contributes.themes.push({
            id: `${safeId(id)}.${e.name}`,
            label: e.name.replace(/\.(icls|xml)$/i, ''),
            path: full,
            uiTheme: 'vs-dark'
          })
        }
      }
    }
  }
  await walk(root)

  // action ids from plugin.xml (metadata / future)
  const actionRe = /<action\b[^>]*>/gi
  let am: RegExpExecArray | null
  while ((am = actionRe.exec(xml))) {
    const actionId = extractXmlAttr(am[0], 'id')
    const text = extractXmlAttr(am[0], 'text')
    if (actionId) {
      contributes.commands.push({
        id: actionId,
        title: text || actionId,
        category: 'IDEA'
      })
    }
  }

  // <toolWindow id="..." anchor="left|right|bottom" icon="..." />
  const toolWindowRe = /<toolWindow\b[^>]*\/?>/gi
  let tw: RegExpExecArray | null
  while ((tw = toolWindowRe.exec(xml))) {
    const tag = tw[0]
    const twId = extractXmlAttr(tag, 'id')
    if (!twId) continue
    const anchor = (extractXmlAttr(tag, 'anchor') || 'left').toLowerCase()
    const icon = extractXmlAttr(tag, 'icon')
    const text = extractXmlAttr(tag, 'text') || extractXmlAttr(tag, 'stripeText')
    contributes.views.push({
      id: twId,
      title: text || twId,
      iconPath: icon && !icon.startsWith('AllIcons') ? icon.replace(/^\//, '') : undefined,
      location: anchor === 'bottom' ? 'panel' : 'activitybar'
    })
  }

  await hydrateViewIcons(root, contributes.views)

  // IDEA plugins without declared toolWindows still get a sidebar entry (skip pure color-scheme packs)
  const themeOnly =
    contributes.themes.length > 0 &&
    contributes.commands.length === 0 &&
    contributes.views.length === 0
  if (contributes.views.length === 0 && !themeOnly) {
    contributes.views.push({
      id: `${safeId(id)}.toolwindow`,
      title: name,
      location: 'activitybar',
      synthetic: true
    })
  }

  return {
    id: safeId(id),
    name,
    version,
    kind: 'idea',
    description,
    publisher: vendor,
    path: root,
    compatibility: contributes.themes.length ? 'partial' : 'metadata',
    compatibilityNote: contributes.themes.length
      ? 'Color schemes can apply. Sidebar buttons are shown as placeholders; JVM UI is not executed.'
      : 'IDEA plugins are JVM-based. Lithe shows sidebar placeholders from toolWindow metadata; runtime code is not loaded.',
    contributes
  }
}

async function parseLithePlugin(root: string): Promise<Omit<PluginInfo, 'enabled'> | null> {
  const manifest = await readJson<any>(path.join(root, 'lithe.plugin.json'))
  if (!manifest?.id) return null
  const contributes = emptyContrib()
  for (const t of manifest.contributes?.themes || []) {
    contributes.themes.push({
      id: String(t.id),
      label: String(t.label || t.id),
      path: path.join(root, t.path),
      uiTheme: t.uiTheme
    })
  }
  for (const c of manifest.contributes?.commands || []) {
    contributes.commands.push({
      id: String(c.id),
      title: String(c.title || c.id),
      category: c.category
    })
  }
  for (const v of manifest.contributes?.views || []) {
    if (!v?.id) continue
    contributes.views.push({
      id: String(v.id),
      title: String(v.title || v.id),
      iconPath: v.icon ? String(v.icon) : undefined,
      location: v.location === 'panel' ? 'panel' : 'activitybar'
    })
  }
  await hydrateViewIcons(root, contributes.views)
  return {
    id: safeId(String(manifest.id)),
    name: String(manifest.name || manifest.id),
    version: String(manifest.version || '0.0.0'),
    kind: 'lithe',
    description: String(manifest.description || ''),
    publisher: String(manifest.publisher || 'lithe'),
    path: root,
    compatibility: 'full',
    compatibilityNote: 'Native Lithe plugin.',
    contributes
  }
}

async function inspectPluginDir(root: string): Promise<Omit<PluginInfo, 'enabled'> | null> {
  return (
    (await parseLithePlugin(root)) ||
    (await parseVscodeExtension(root)) ||
    (await parseIdeaPlugin(root))
  )
}

async function listInstalled(): Promise<PluginInfo[]> {
  await ensureDirs()
  const state = await loadState()
  const entries = await fsp.readdir(installedRoot(), { withFileTypes: true })
  const out: PluginInfo[] = []

  for (const e of entries) {
    if (!e.isDirectory()) continue
    const dir = path.join(installedRoot(), e.name)
    const info = await inspectPluginDir(dir)
    if (!info) continue
    const enabled = state.enabled[info.id] !== false
    out.push({ ...info, enabled })
  }

  out.sort((a, b) => a.name.localeCompare(b.name))
  installedPathCache.clear()
  for (const p of out) installedPathCache.set(p.id, p.path)
  updatePluginStaticRoots(installedPathCache)
  return out
}

const installedPathCache = new Map<string, string>()

export function getCachedPluginPath(pluginId: string): string | null {
  return installedPathCache.get(pluginId) || null
}

async function rimraf(target: string): Promise<void> {
  await fsp.rm(target, { recursive: true, force: true })
}

async function copyDir(src: string, dest: string): Promise<void> {
  await fsp.mkdir(dest, { recursive: true })
  const entries = await fsp.readdir(src, { withFileTypes: true })
  for (const e of entries) {
    const from = path.join(src, e.name)
    const to = path.join(dest, e.name)
    if (e.isDirectory()) await copyDir(from, to)
    else await fsp.copyFile(from, to)
  }
}

async function extractArchive(archive: string, dest: string): Promise<void> {
  await fsp.mkdir(dest, { recursive: true })
  // Windows 10+ tar extracts zip/vsix/jar
  await execFileAsync('tar', ['-xf', archive, '-C', dest], { windowsHide: true })
}

function httpGetBuffer(url: string, redirects = 0): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    if (redirects > 8) {
      reject(new Error('Too many redirects'))
      return
    }
    const lib = url.startsWith('https') ? https : http
    const req = lib.get(
      url,
      {
        headers: {
          'User-Agent': 'Lithe-IDEA/0.1',
          Accept: '*/*'
        },
        timeout: 20_000
      },
      (res) => {
        if (res.statusCode && res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
          const next = new URL(res.headers.location, url).toString()
          res.resume()
          resolve(httpGetBuffer(next, redirects + 1))
          return
        }
        if (!res.statusCode || res.statusCode >= 400) {
          reject(new Error(`Download failed: HTTP ${res.statusCode}`))
          res.resume()
          return
        }
        const chunks: Buffer[] = []
        res.on('data', (c) => chunks.push(c))
        res.on('end', () => resolve(Buffer.concat(chunks)))
        res.on('error', reject)
      }
    )
    req.on('timeout', () => {
      req.destroy()
      reject(new Error(`Request timed out: ${url}`))
    })
    req.on('error', reject)
  })
}

/** JetBrains Marketplace returns vendor as `{ name, isVerified }` or a plain string. */
function vendorName(vendor: unknown, fallback = 'JetBrains'): string {
  if (typeof vendor === 'string' && vendor.trim()) return vendor.trim()
  if (vendor && typeof vendor === 'object' && 'name' in vendor) {
    const n = (vendor as { name?: unknown }).name
    if (typeof n === 'string' && n.trim()) return n.trim()
  }
  return fallback
}

function httpGetJson<T>(url: string): Promise<T> {
  return httpGetBuffer(url).then((buf) => JSON.parse(buf.toString('utf8')) as T)
}

async function installFromDirectory(sourceDir: string): Promise<PluginInfo> {
  await ensureDirs()
  const inspected = await inspectPluginDir(sourceDir)
  if (!inspected) {
    throw new Error('Unrecognized plugin (need package.json, META-INF/plugin.xml, or lithe.plugin.json)')
  }

  const dest = path.join(installedRoot(), safeId(inspected.id))
  if (path.resolve(sourceDir) !== path.resolve(dest)) {
    await rimraf(dest)
    await copyDir(sourceDir, dest)
  }

  const finalInfo = (await inspectPluginDir(dest)) || inspected
  const state = await loadState()
  if (state.enabled[finalInfo.id] === undefined) {
    state.enabled[finalInfo.id] = true
    await saveState(state)
  }

  return { ...finalInfo, enabled: state.enabled[finalInfo.id] !== false }
}

async function installFromArchive(archivePath: string): Promise<PluginInfo> {
  await ensureDirs()
  const tmp = path.join(pluginsRoot(), `_tmp_${Date.now()}`)
  try {
    await extractArchive(archivePath, tmp)
    // vsix often has top-level "extension/"
    const candidates = [tmp, path.join(tmp, 'extension')]
    let installed: PluginInfo | null = null
    for (const c of candidates) {
      if (await pathExists(c)) {
        try {
          installed = await installFromDirectory(c)
          break
        } catch {
          /* try next */
        }
      }
    }
    if (!installed) {
      // maybe single nested folder
      const entries = await fsp.readdir(tmp, { withFileTypes: true })
      const dirs = entries.filter((e) => e.isDirectory())
      if (dirs.length === 1) {
        installed = await installFromDirectory(path.join(tmp, dirs[0].name))
      }
    }
    if (!installed) throw new Error('Could not parse plugin archive')
    return installed
  } finally {
    await rimraf(tmp)
  }
}

async function installFromPath(target: string): Promise<PluginInfo> {
  const st = await fsp.stat(target)
  if (st.isDirectory()) return installFromDirectory(target)
  const ext = path.extname(target).toLowerCase()
  if (['.vsix', '.zip', '.jar'].includes(ext)) return installFromArchive(target)
  throw new Error('Supported: folder, .vsix, .zip, .jar')
}

async function searchOpenVsx(query: string): Promise<MarketplacePlugin[]> {
  const q = encodeURIComponent(query.trim() || 'theme')
  const url2 = `https://open-vsx.org/api/-/search?query=${q}&size=24&sortBy=relevance&sortOrder=desc`
  try {
    const data = await httpGetJson<any>(url2)
    const installed = new Set((await listInstalled()).map((p) => p.id.toLowerCase()))
    return (data.extensions || []).map((ext: any) => {
      const id = `${ext.namespace}.${ext.name}`
      return {
        id,
        name: ext.displayName || ext.name,
        version: ext.version,
        kind: 'vscode' as const,
        description: ext.description || '',
        publisher: ext.namespace,
        downloads: ext.downloadCount,
        url: `https://open-vsx.org/extension/${ext.namespace}/${ext.name}`,
        installed: installed.has(id.toLowerCase()),
        namespace: ext.namespace,
        extensionName: ext.name,
        marketId: id
      }
    })
  } catch (err: any) {
    throw new Error(`Open VSX search failed: ${err?.message || err}`)
  }
}

async function searchJetBrains(query: string): Promise<MarketplacePlugin[]> {
  const q = encodeURIComponent(query.trim() || 'theme')
  const url = `https://plugins.jetbrains.com/api/searchPlugins?max=24&offset=0&search=${q}`
  try {
    const data = await httpGetJson<any>(url)
    const installed = new Set((await listInstalled()).map((p) => p.id.toLowerCase()))
    const plugins = data.plugins || data || []
    return (Array.isArray(plugins) ? plugins : []).map((p: any) => {
      const xmlId = String(p.xmlId || p.id || p.name)
      const numericId = p.id != null ? String(p.id) : undefined
      return {
        id: xmlId,
        name: String(p.name || xmlId),
        version: String(p.version || ''),
        kind: 'idea' as const,
        description: String(p.preview || p.description || '')
          .replace(/<[^>]+>/g, '')
          .slice(0, 280),
        publisher: vendorName(p.vendor, vendorName(p.organization, 'JetBrains')),
        downloads: typeof p.downloads === 'number' ? p.downloads : undefined,
        url: numericId
          ? `https://plugins.jetbrains.com/plugin/${numericId}`
          : `https://plugins.jetbrains.com/search?search=${encodeURIComponent(p.name || xmlId)}`,
        installed: installed.has(safeId(xmlId).toLowerCase()),
        marketId: numericId || xmlId
      }
    })
  } catch (err: any) {
    throw new Error(`JetBrains Marketplace search failed: ${err?.message || err}`)
  }
}

async function installFromOpenVsx(
  namespace: string,
  name: string,
  version?: string,
  downloadUrl?: string
): Promise<PluginInfo> {
  let download = downloadUrl
  let ver = version || 'latest'
  if (!download) {
    const metaUrl = version
      ? `https://open-vsx.org/api/${namespace}/${name}/${encodeURIComponent(version)}`
      : `https://open-vsx.org/api/${namespace}/${name}/latest`
    try {
      const meta = await httpGetJson<any>(metaUrl)
      download = meta.files?.download || meta.downloadUrl || meta.files?.vsix
      ver = String(meta.version || version || 'latest')
    } catch (err) {
      if (!version) throw err
      // Fall back to VS Code Marketplace VSIX for versions missing on Open VSX
      const gallery = await listVsCodeGalleryVersions(`${namespace}.${name}`)
      const hit = gallery.find((g) => g.version === version)
      if (!hit?.downloadUrl) throw err
      download = hit.downloadUrl
      ver = hit.version
    }
  }
  if (!download) throw new Error('No download URL from Open VSX / VS Code Marketplace')
  const buf = await httpGetBuffer(download)
  const tmpFile = path.join(pluginsRoot(), `_dl_${Date.now()}_${safeId(ver)}.vsix`)
  await ensureDirs()
  await fsp.writeFile(tmpFile, buf)
  try {
    return await installFromArchive(tmpFile)
  } finally {
    await fsp.unlink(tmpFile).catch(() => undefined)
  }
}

async function resolveJetBrainsNumericId(pluginId: string): Promise<string> {
  if (/^\d+$/.test(pluginId)) return pluginId
  const results = await searchJetBrains(pluginId)
  const hit = results.find((r) => r.id === pluginId) || results[0]
  if (!hit?.url) throw new Error('Plugin not found on JetBrains Marketplace')
  const m = hit.url.match(/plugin\/(\d+)/)
  if (!m) throw new Error('Could not resolve JetBrains plugin id')
  return m[1]
}

async function installFromJetBrains(pluginId: string, updateId?: string): Promise<PluginInfo> {
  let downloadUrl = ''
  if (updateId && /^\d+$/.test(updateId)) {
    downloadUrl = `https://plugins.jetbrains.com/plugin/download?rel=true&updateId=${updateId}`
  } else {
    const numericId = await resolveJetBrainsNumericId(pluginId)
    downloadUrl = `https://plugins.jetbrains.com/plugin/download?rel=true&pluginId=${numericId}`
  }

  const buf = await httpGetBuffer(downloadUrl)
  const tmpFile = path.join(pluginsRoot(), `_dl_${Date.now()}.zip`)
  await ensureDirs()
  await fsp.writeFile(tmpFile, buf)
  try {
    return await installFromArchive(tmpFile)
  } finally {
    await fsp.unlink(tmpFile).catch(() => undefined)
  }
}

async function listOpenVsxVersions(namespace: string, name: string): Promise<MarketplaceVersion[]> {
  const pageSize = 100 // Open VSX hard max
  const hardCap = 500
  const out: MarketplaceVersion[] = []
  const seen = new Set<string>()
  let offset = 0
  let total = Infinity

  while (offset < total && out.length < hardCap) {
    const data = await httpGetJson<any>(
      `https://open-vsx.org/api/${encodeURIComponent(namespace)}/${encodeURIComponent(name)}/versions?size=${pageSize}&offset=${offset}`
    )
    total = typeof data.totalSize === 'number' ? data.totalSize : offset
    const map = data.versions || {}
    const keys = Object.keys(map)
    if (keys.length === 0) break
    for (const ver of keys) {
      if (seen.has(ver)) continue
      seen.add(ver)
      out.push({ version: ver })
      if (out.length >= hardCap) break
    }
    offset += keys.length
    if (keys.length < pageSize) break
  }

  // Enrich with VS Code Marketplace metadata when available (dates / extra builds)
  try {
    const gallery = await listVsCodeGalleryVersions(`${namespace}.${name}`)
    for (const g of gallery) {
      if (seen.has(g.version)) {
        const hit = out.find((v) => v.version === g.version)
        if (hit) {
          if (!hit.publishedAt && g.publishedAt) hit.publishedAt = g.publishedAt
          if (!hit.downloadUrl && g.downloadUrl) hit.downloadUrl = g.downloadUrl
        }
        continue
      }
      seen.add(g.version)
      out.push(g)
    }
  } catch {
    /* gallery optional */
  }

  return out
}

/** VS Code Marketplace gallery — fewer rows than Open VSX but useful dates / fallback. */
async function listVsCodeGalleryVersions(extensionId: string): Promise<MarketplaceVersion[]> {
  const [publisher, ...rest] = extensionId.split('.')
  const name = rest.join('.')
  if (!publisher || !name) return []

  const body = JSON.stringify({
    filters: [
      {
        criteria: [{ filterType: 7, value: extensionId }],
        pageNumber: 1,
        pageSize: 1
      }
    ],
    // IncludeVersions | IncludeFiles | IncludeVersionProperties
    flags: 0x200 | 0x2 | 0x400
  })

  const raw = await httpPostJson<any>(
    'https://marketplace.visualstudio.com/_apis/public/gallery/extensionquery?api-version=7.2-preview.1',
    body
  )
  const ext = raw?.results?.[0]?.extensions?.[0]
  const versions = Array.isArray(ext?.versions) ? ext.versions : []
  const out: MarketplaceVersion[] = []
  const seen = new Set<string>()
  for (const v of versions) {
    const ver = String(v.version || '')
    if (!ver || seen.has(ver)) continue
    seen.add(ver)
    const asset = Array.isArray(v.files)
      ? v.files.find((f: any) => f.assetType === 'Microsoft.VisualStudio.Services.VSIXPackage')
      : null
    out.push({
      version: ver,
      publishedAt: v.lastUpdated ? new Date(v.lastUpdated).toISOString() : undefined,
      downloadUrl: asset?.source || undefined
    })
  }
  return out
}

function httpPostJson<T>(url: string, body: string): Promise<T> {
  return new Promise((resolve, reject) => {
    const u = new URL(url)
    const lib = u.protocol === 'https:' ? https : http
    const req = lib.request(
      {
        protocol: u.protocol,
        hostname: u.hostname,
        port: u.port || undefined,
        path: u.pathname + u.search,
        method: 'POST',
        headers: {
          'User-Agent': 'Lithe-IDEA/0.1',
          Accept: 'application/json;api-version=7.2-preview.1;excludeUrls=true',
          'Content-Type': 'application/json',
          'Content-Length': Buffer.byteLength(body)
        },
        timeout: 20_000
      },
      (res) => {
        if (res.statusCode && res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
          res.resume()
          resolve(httpPostJson<T>(new URL(res.headers.location, url).toString(), body))
          return
        }
        const chunks: Buffer[] = []
        res.on('data', (c) => chunks.push(c))
        res.on('end', () => {
          if (!res.statusCode || res.statusCode >= 400) {
            reject(new Error(`HTTP ${res.statusCode}`))
            return
          }
          try {
            resolve(JSON.parse(Buffer.concat(chunks).toString('utf8')) as T)
          } catch (err) {
            reject(err)
          }
        })
        res.on('error', reject)
      }
    )
    req.on('timeout', () => {
      req.destroy()
      reject(new Error(`Request timed out: ${url}`))
    })
    req.on('error', reject)
    req.write(body)
    req.end()
  })
}

async function listJetBrainsVersions(pluginId: string): Promise<MarketplaceVersion[]> {
  const numericId = await resolveJetBrainsNumericId(pluginId)
  const pageSize = 100
  const hardCap = 500
  const out: MarketplaceVersion[] = []
  const seen = new Set<string>()

  for (let page = 1; page <= 20 && out.length < hardCap; page++) {
    const updates = await httpGetJson<any[]>(
      `https://plugins.jetbrains.com/api/plugins/${numericId}/updates?size=${pageSize}&page=${page}`
    )
    const list = Array.isArray(updates) ? updates : []
    if (list.length === 0) break
    for (const u of list) {
      if (!u || u.listed === false || u.hidden === true) continue
      const key = `${u.version}:${u.id}`
      if (seen.has(key)) continue
      seen.add(key)
      out.push({
        version: String(u.version || u.id),
        updateId: u.id != null ? String(u.id) : undefined,
        publishedAt: u.cdate ? new Date(Number(u.cdate)).toISOString() : undefined,
        downloads: typeof u.downloads === 'number' ? u.downloads : undefined,
        sinceUntil: String(u.sinceUntil || (u.since ? `${u.since}+` : '') || ''),
        channel: String(u.channel || 'stable'),
        size: typeof u.size === 'number' ? u.size : undefined
      })
      if (out.length >= hardCap) break
    }
    if (list.length < pageSize) break
  }
  return out
}

async function listMarketplaceVersions(
  kind: PluginKind,
  id: string,
  extra?: MarketplaceInstallOptions
): Promise<MarketplaceVersion[]> {
  if (kind === 'vscode') {
    let ns = extra?.namespace
    let name = extra?.name || extra?.extensionName
    if ((!ns || !name) && id.includes('.')) {
      const i = id.indexOf('.')
      ns = id.slice(0, i)
      name = id.slice(i + 1)
    }
    if (!ns || !name) throw new Error('Invalid VS Code extension id (publisher.name)')
    try {
      return await listOpenVsxVersions(ns, name)
    } catch (err: any) {
      throw new Error(`Open VSX versions failed: ${err?.message || err}`)
    }
  }
  if (kind === 'idea') {
    try {
      return await listJetBrainsVersions(extra?.marketId || id)
    } catch (err: any) {
      throw new Error(`JetBrains versions failed: ${err?.message || err}`)
    }
  }
  throw new Error('Unsupported marketplace kind')
}

function defaultExportFormat(kind: PluginKind): MarketplaceExportFormat {
  if (kind === 'vscode') return 'vsix'
  if (kind === 'idea') return 'zip'
  return 'zip'
}

function exportFilters(kind: PluginKind): Electron.FileFilter[] {
  if (kind === 'vscode') {
    return [
      { name: 'VS Code Extension (*.vsix)', extensions: ['vsix'] },
      { name: 'Zip Archive (*.zip)', extensions: ['zip'] }
    ]
  }
  if (kind === 'idea') {
    return [
      { name: 'IntelliJ Plugin Zip (*.zip)', extensions: ['zip'] },
      { name: 'IntelliJ Plugin Jar (*.jar)', extensions: ['jar'] }
    ]
  }
  return [{ name: 'Zip Archive (*.zip)', extensions: ['zip'] }]
}

async function resolveMarketDownload(
  kind: PluginKind,
  id: string,
  extra?: MarketplaceInstallOptions
): Promise<{ url: string; suggestedName: string; format: MarketplaceExportFormat }> {
  if (kind === 'vscode') {
    let ns = extra?.namespace
    let name = extra?.name || extra?.extensionName
    if ((!ns || !name) && id.includes('.')) {
      const i = id.indexOf('.')
      ns = id.slice(0, i)
      name = id.slice(i + 1)
    }
    if (!ns || !name) throw new Error('Invalid VS Code extension id')
    if (extra?.downloadUrl) {
      const ver = extra.version || 'export'
      return {
        url: extra.downloadUrl,
        suggestedName: `${ns}.${name}-${safeId(ver)}.vsix`,
        format: 'vsix'
      }
    }
    const metaUrl = extra?.version
      ? `https://open-vsx.org/api/${ns}/${name}/${encodeURIComponent(extra.version)}`
      : `https://open-vsx.org/api/${ns}/${name}/latest`
    try {
      const meta = await httpGetJson<any>(metaUrl)
      const download = meta.files?.download || meta.downloadUrl || meta.files?.vsix
      if (!download) throw new Error('No download URL from Open VSX')
      const ver = String(meta.version || extra?.version || 'latest')
      return {
        url: download,
        suggestedName: `${ns}.${name}-${ver}.vsix`,
        format: 'vsix'
      }
    } catch (err) {
      if (!extra?.version) throw err
      const gallery = await listVsCodeGalleryVersions(`${ns}.${name}`)
      const hit = gallery.find((g) => g.version === extra.version)
      if (!hit?.downloadUrl) throw err
      return {
        url: hit.downloadUrl,
        suggestedName: `${ns}.${name}-${hit.version}.vsix`,
        format: 'vsix'
      }
    }
  }
  if (kind === 'idea') {
    const format: MarketplaceExportFormat = 'zip'
    let downloadUrl = ''
    let verLabel = extra?.version || 'latest'
    if (extra?.updateId && /^\d+$/.test(extra.updateId)) {
      downloadUrl = `https://plugins.jetbrains.com/plugin/download?rel=true&updateId=${extra.updateId}`
    } else {
      const numericId = await resolveJetBrainsNumericId(extra?.marketId || id)
      if (extra?.version) {
        const versions = await listJetBrainsVersions(numericId)
        const hit =
          versions.find((v) => v.version === extra.version) ||
          versions.find((v) => v.version.startsWith(extra.version!))
        if (!hit?.updateId) throw new Error(`Version ${extra.version} not found`)
        downloadUrl = `https://plugins.jetbrains.com/plugin/download?rel=true&updateId=${hit.updateId}`
        verLabel = hit.version
      } else {
        downloadUrl = `https://plugins.jetbrains.com/plugin/download?rel=true&pluginId=${numericId}`
      }
    }
    return {
      url: downloadUrl,
      suggestedName: `${safeId(id)}-${safeId(verLabel)}.zip`,
      format
    }
  }
  throw new Error('Unsupported marketplace kind')
}

async function exportMarketplacePlugin(
  kind: PluginKind,
  id: string,
  extra?: MarketplaceInstallOptions
): Promise<MarketplaceExportResult> {
  try {
    const resolved = await resolveMarketDownload(kind, id, extra)
    const win = BrowserWindow.getFocusedWindow()
    const filters = exportFilters(kind)
    const saveOpts: Electron.SaveDialogOptions = {
      title: 'Export Plugin',
      defaultPath: resolved.suggestedName,
      filters
    }
    const result = win
      ? await dialog.showSaveDialog(win, saveOpts)
      : await dialog.showSaveDialog(saveOpts)
    if (result.canceled || !result.filePath) return { ok: false, canceled: true }

    let outPath = result.filePath
    const ext = path.extname(outPath).toLowerCase()
    if (!ext) {
      outPath += resolved.format === 'vsix' ? '.vsix' : resolved.format === 'jar' ? '.jar' : '.zip'
    }
    const buf = await httpGetBuffer(resolved.url)
    await fsp.writeFile(outPath, buf)
    const format = (path.extname(outPath).slice(1).toLowerCase() || resolved.format) as MarketplaceExportFormat
    return { ok: true, path: outPath, format }
  } catch (err: any) {
    return { ok: false, error: err?.message || String(err) }
  }
}

async function packDirectory(sourceDir: string, outFile: string): Promise<void> {
  await fsp.mkdir(path.dirname(outFile), { recursive: true })
  // tar on Windows 10+ creates zip when extension is .zip; for .vsix/.jar use zip via PowerShell
  const ext = path.extname(outFile).toLowerCase()
  if (ext === '.zip' || ext === '.vsix' || ext === '.jar') {
    // Compress-Archive cannot write .vsix/.jar directly — zip then rename
    const tmpZip = outFile.replace(/\.(vsix|jar)$/i, '') + '.__tmp__.zip'
    const targetZip = ext === '.zip' ? outFile : tmpZip
    if (await pathExists(targetZip)) await fsp.unlink(targetZip)
    if (await pathExists(outFile) && outFile !== targetZip) await fsp.unlink(outFile)
    const ps = `Compress-Archive -Path (Join-Path -Path '${sourceDir.replace(/'/g, "''")}' -ChildPath '*') -DestinationPath '${targetZip.replace(/'/g, "''")}' -Force`
    await execFileAsync('powershell.exe', ['-NoProfile', '-Command', ps], { windowsHide: true })
    if (ext !== '.zip') {
      await fsp.rename(targetZip, outFile)
    }
    return
  }
  await execFileAsync('tar', ['-a', '-cf', outFile, '-C', sourceDir, '.'], { windowsHide: true })
}

async function exportInstalledPlugin(id: string): Promise<MarketplaceExportResult> {
  try {
    const list = await listInstalled()
    const hit = list.find((p) => p.id === id)
    if (!hit) return { ok: false, error: 'Plugin not found' }
    const format = defaultExportFormat(hit.kind)
    const suggested = `${safeId(hit.id)}-${safeId(hit.version || 'export')}.${format}`
    const win = BrowserWindow.getFocusedWindow()
    const saveOpts: Electron.SaveDialogOptions = {
      title: 'Export Installed Plugin',
      defaultPath: suggested,
      filters: exportFilters(hit.kind)
    }
    const result = win
      ? await dialog.showSaveDialog(win, saveOpts)
      : await dialog.showSaveDialog(saveOpts)
    if (result.canceled || !result.filePath) return { ok: false, canceled: true }

    let outPath = result.filePath
    const ext = path.extname(outPath).toLowerCase()
    if (!ext) outPath += `.${format}`

    // Prefer packing the plugin root (directory that contains package.json / plugin.xml)
    await packDirectory(hit.path, outPath)
    const outFormat = (path.extname(outPath).slice(1).toLowerCase() || format) as MarketplaceExportFormat
    return { ok: true, path: outPath, format: outFormat }
  } catch (err: any) {
    return { ok: false, error: err?.message || String(err) }
  }
}

async function activeContributions(): Promise<{
  plugins: PluginInfo[]
  themes: Array<PluginThemeContribution & { pluginId: string; pluginName: string }>
  commands: Array<PluginCommandContribution & { pluginId: string; pluginName: string }>
  views: Array<PluginViewContribution & { pluginId: string; pluginName: string; pluginKind: PluginKind }>
  themeContents: Record<string, unknown>
}> {
  const plugins = (await listInstalled()).filter((p) => p.enabled)
  const themes: Array<PluginThemeContribution & { pluginId: string; pluginName: string }> = []
  const commands: Array<PluginCommandContribution & { pluginId: string; pluginName: string }> = []
  const views: Array<
    PluginViewContribution & { pluginId: string; pluginName: string; pluginKind: PluginKind }
  > = []
  const themeContents: Record<string, unknown> = {}

  for (const p of plugins) {
    for (const t of p.contributes.themes) {
      themes.push({ ...t, pluginId: p.id, pluginName: p.name })
      try {
        if (t.path.endsWith('.json')) {
          themeContents[t.id] = JSON.parse(await fsp.readFile(t.path, 'utf8'))
        } else if (t.path.endsWith('.icls') || t.path.endsWith('.xml')) {
          themeContents[t.id] = { type: 'idea-icls', xml: await fsp.readFile(t.path, 'utf8') }
        }
      } catch {
        /* skip unreadable theme */
      }
    }
    for (const c of p.contributes.commands) {
      commands.push({ ...c, pluginId: p.id, pluginName: p.name })
    }
    for (const v of p.contributes.views || []) {
      if (v.location !== 'activitybar') continue
      views.push({ ...v, pluginId: p.id, pluginName: p.name, pluginKind: p.kind })
    }
  }

  return { plugins, themes, commands, views, themeContents }
}

export function registerPluginHandlers(): void {
  ipcMain.handle(IPC.PLUGIN_LIST, async () => listInstalled())

  ipcMain.handle(IPC.PLUGIN_SET_ENABLED, async (_e, id: string, enabled: boolean) => {
    const state = await loadState()
    state.enabled[id] = enabled
    await saveState(state)
    return listInstalled()
  })

  ipcMain.handle(IPC.PLUGIN_UNINSTALL, async (_e, id: string) => {
    const list = await listInstalled()
    const hit = list.find((p) => p.id === id)
    if (!hit) throw new Error('Plugin not found')
    // remove install folder (parent under installed/)
    const parent = path.dirname(hit.path)
    const target =
      path.resolve(parent) === path.resolve(installedRoot()) ? hit.path : path.join(installedRoot(), safeId(id))
    // Prefer directory named after id
    const byId = path.join(installedRoot(), safeId(id))
    if (await pathExists(byId)) await rimraf(byId)
    else {
      // remove the inspected root if it's directly under installed
      const rel = path.relative(installedRoot(), hit.path)
      const top = rel.split(/[\\/]/)[0]
      if (top && !top.startsWith('..')) await rimraf(path.join(installedRoot(), top))
    }
    const state = await loadState()
    delete state.enabled[id]
    await saveState(state)
    return listInstalled()
  })

  ipcMain.handle(IPC.PLUGIN_INSTALL_PATH, async (_e, target: string) => {
    if (!target) throw new Error('No path')
    return installFromPath(target)
  })

  ipcMain.handle(IPC.PLUGIN_INSTALL_DIALOG, async () => {
    const win = BrowserWindow.getFocusedWindow()
    const opts: Electron.OpenDialogOptions = {
      title: 'Install Plugin',
      properties: ['openFile', 'openDirectory'],
      filters: [
        { name: 'Plugins', extensions: ['vsix', 'jar', 'zip'] },
        { name: 'All', extensions: ['*'] }
      ]
    }
    const result = win
      ? await dialog.showOpenDialog(win, opts)
      : await dialog.showOpenDialog(opts)
    if (result.canceled || !result.filePaths[0]) return null
    return installFromPath(result.filePaths[0])
  })

  ipcMain.handle(IPC.PLUGIN_SEARCH_MARKET, async (_e, kind: PluginKind | 'all', query: string) => {
    const q = query || ''
    if (kind === 'vscode') return searchOpenVsx(q)
    if (kind === 'idea') return searchJetBrains(q)
    const [vs, idea] = await Promise.allSettled([searchOpenVsx(q), searchJetBrains(q)])
    const out: MarketplacePlugin[] = []
    if (vs.status === 'fulfilled') out.push(...vs.value)
    if (idea.status === 'fulfilled') out.push(...idea.value)
    if (out.length === 0) {
      const errs = [vs, idea]
        .filter((r): r is PromiseRejectedResult => r.status === 'rejected')
        .map((r) => String(r.reason?.message || r.reason))
      if (errs.length) throw new Error(errs.join(' · '))
    }
    return out
  })

  ipcMain.handle(
    IPC.PLUGIN_LIST_VERSIONS,
    async (_e, kind: PluginKind, id: string, extra?: MarketplaceInstallOptions) =>
      listMarketplaceVersions(kind, id, extra)
  )

  ipcMain.handle(
    IPC.PLUGIN_INSTALL_MARKET,
    async (_e, kind: PluginKind, id: string, extra?: MarketplaceInstallOptions) => {
      if (kind === 'vscode') {
        let ns = extra?.namespace
        let name = extra?.name || extra?.extensionName
        if ((!ns || !name) && id.includes('.')) {
          const i = id.indexOf('.')
          ns = id.slice(0, i)
          name = id.slice(i + 1)
        }
        if (!ns || !name) throw new Error('Invalid VS Code extension id (publisher.name)')
        return installFromOpenVsx(ns, name, extra?.version, extra?.downloadUrl)
      }
      if (kind === 'idea') {
        let updateId = extra?.updateId
        if (!updateId && extra?.version) {
          const versions = await listJetBrainsVersions(extra.marketId || id)
          const hit = versions.find((v) => v.version === extra.version)
          updateId = hit?.updateId
          if (!updateId) throw new Error(`Version ${extra.version} not found on JetBrains Marketplace`)
        }
        return installFromJetBrains(extra?.marketId || id, updateId)
      }
      throw new Error('Unsupported marketplace kind')
    }
  )

  ipcMain.handle(
    IPC.PLUGIN_EXPORT_MARKET,
    async (_e, kind: PluginKind, id: string, extra?: MarketplaceInstallOptions) =>
      exportMarketplacePlugin(kind, id, extra)
  )

  ipcMain.handle(IPC.PLUGIN_EXPORT_INSTALLED, async (_e, id: string) => exportInstalledPlugin(id))

  ipcMain.handle(IPC.PLUGIN_CONTRIBUTIONS, async () => activeContributions())

  ipcMain.handle(IPC.PLUGIN_WEBVIEW_URL, async (_e, pluginId: string, cwd?: string) => {
    const list = await listInstalled()
    const hit = list.find((p) => p.id === pluginId && p.enabled)
    if (!hit) return { ok: false as const, error: 'Plugin not found' }
    if (hit.kind !== 'vscode' || !detectVscodeWebviewAssets(hit.path)) {
      return { ok: false as const, error: 'No webview UI assets in this plugin' }
    }
    await ensurePluginStaticServer()
    updatePluginStaticRoots(installedPathCache)

    // Try Extension Host before returning URL
    let hostRunning = false
    try {
      const host = await startExtensionHost({
        pluginId: hit.id,
        extensionPath: hit.path,
        cwd
      })
      hostRunning = host.status === 'running'
    } catch (err: any) {
      console.warn('[plugin] host ensure failed', err?.message || err)
    }

    let url = pluginWebviewHttpUrl(hit.id)
    if (!url) {
      url = pluginSidebarUrl(hit.id)
    } else {
      const qs = new URLSearchParams()
      if (cwd) qs.set('cwd', cwd)
      if (hostRunning) qs.set('host', '1')
      // Cache-bust so a restarted host always serves its fresh resolved HTML
      qs.set('t', String(Date.now()))
      const q = qs.toString()
      if (q) url += `?${q}`
    }
    const host = getExtensionHost(hit.id)
    return {
      ok: true as const,
      url,
      title: hit.name,
      hostStatus: host?.status || 'idle',
      hostError: host?.error
    }
  })

  ipcMain.handle(IPC.PLUGIN_HOST_ENSURE, async (_e, pluginId: string, cwd?: string) => {
    const list = await listInstalled()
    const hit = list.find((p) => p.id === pluginId)
    if (!hit) return { ok: false as const, error: 'Plugin not found' }
    const host = await startExtensionHost({
      pluginId: hit.id,
      extensionPath: hit.path,
      cwd
    })
    return {
      ok: host.status === 'running',
      status: host.status,
      error: host.error,
      viewType: host.viewType
    }
  })

  ipcMain.handle(IPC.PLUGIN_HOST_POST, async (_e, pluginId: string, message: unknown) => {
    return { ok: postToExtensionHost(pluginId, message) }
  })

  ipcMain.handle(
    IPC.PLUGIN_EXECUTE_COMMAND,
    async (_e, pluginId: string, commandId: string, args?: unknown[]) =>
      executeExtensionCommand(pluginId, commandId, ...(Array.isArray(args) ? args : []))
  )

  ipcMain.handle(IPC.PLUGIN_OPEN_FOLDER, async () => {
    await ensureDirs()
    await shell.openPath(installedRoot())
    return installedRoot()
  })
}

/** Resolve on-disk root for lithe-plugin:// protocol (enabled or not). */
export async function resolveInstalledPluginPath(pluginId: string): Promise<string | null> {
  const list = await listInstalled()
  const hit = list.find((p) => p.id === pluginId)
  return hit?.path || null
}

/** Snapshot of installed plugin id → path for the custom protocol handler. */
export async function mapInstalledPluginPaths(): Promise<Map<string, string>> {
  // listInstalled refreshes installedPathCache
  await listInstalled()
  return new Map(installedPathCache)
}
