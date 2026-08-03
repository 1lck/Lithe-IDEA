export interface FileNode {
  path: string
  name: string
  isDirectory: boolean
  children?: FileNode[]
}

export interface RecentProject {
  path: string
  name: string
  lastOpened: number // timestamp
}

export interface EditorDocument {
  id: string
  path: string
  name: string
  content: string
  savedContent: string
  isReadOnly: boolean
  language: string
}

export interface SearchResult {
  kind: 'file' | 'content' | 'type' | 'symbol'
  path: string
  line?: number
  preview: string
  symbolName?: string
}

export interface GitStatus {
  branch: string
  staged: GitFileChange[]
  unstaged: GitFileChange[]
  untracked: string[]
}

export interface GitFileChange {
  path: string
  status: 'modified' | 'added' | 'deleted' | 'renamed' | 'copied'
}

export interface GitLogEntry {
  hash: string
  shortHash: string
  author: string
  email: string
  date: string
  message: string
  parents: string[]
  refs: string[]
}

export interface GitGraphNode {
  commit: GitLogEntry
  column: number
  edges: GitGraphEdge[]
}

export interface GitGraphEdge {
  fromColumn: number
  toColumn: number
  color: string
}

export interface JavaRunConfig {
  name: string
  mainClass: string
  modulePath?: string
  args: string
  vmOptions: string
  jdkPath: string
  workingDirectory: string
}

export interface JdkInfo {
  path: string
  version: string
  vendor: string
}

export interface MavenModule {
  name: string
  path: string
  artifactId: string
  groupId: string
}

export interface LocalHistoryEntry {
  timestamp: number
  path: string
  content: string
}

export interface AppSettings {
  language: 'en' | 'zh-Hans'
  editorFontSize: number
  tabWidth: number
  showCodeVision: boolean
  autoSave: boolean
  autoSaveDelay: number
  terminalShell: 'system' | 'powershell' | 'cmd' | 'gitbash'
  hiddenDirectories: string[]
  hiddenFilePatterns: string[]
}

/** Installed / marketplace plugin identity */
export type PluginKind = 'vscode' | 'idea' | 'lithe'

export interface PluginThemeContribution {
  id: string
  label: string
  path: string
  uiTheme?: 'vs' | 'vs-dark' | 'hc-black'
}

export interface PluginCommandContribution {
  id: string
  title: string
  category?: string
}

export interface PluginSnippetContribution {
  language: string
  path: string
}

export interface PluginContributions {
  themes: PluginThemeContribution[]
  commands: PluginCommandContribution[]
  snippets: PluginSnippetContribution[]
  languages: string[]
}

export interface PluginInfo {
  id: string
  name: string
  version: string
  kind: PluginKind
  description: string
  publisher: string
  enabled: boolean
  path: string
  icon?: string
  compatibility: 'full' | 'partial' | 'metadata'
  compatibilityNote?: string
  contributes: PluginContributions
}

export interface MarketplacePlugin {
  id: string
  name: string
  version: string
  kind: PluginKind
  description: string
  publisher: string
  downloads?: number
  url?: string
  installed?: boolean
  /** JetBrains numeric plugin id / Open VSX namespace.name */
  marketId?: string
  namespace?: string
  extensionName?: string
}

/** A selectable release from Open VSX or JetBrains Marketplace. */
export interface MarketplaceVersion {
  version: string
  /** JetBrains update id — required for versioned download */
  updateId?: string
  publishedAt?: string
  downloads?: number
  /** Human-readable IDE compatibility (e.g. "253.0+") */
  sinceUntil?: string
  channel?: string
  size?: number
  /** Direct download URL when known (Open VSX) */
  downloadUrl?: string
}

export type MarketplaceExportFormat = 'vsix' | 'zip' | 'jar'

export interface MarketplaceInstallOptions {
  namespace?: string
  name?: string
  extensionName?: string
  marketId?: string
  /** Pin a specific version (Open VSX semver / JetBrains version string) */
  version?: string
  /** JetBrains update id for exact build */
  updateId?: string
  /** Direct VSIX / package URL when known (VS Code Gallery) */
  downloadUrl?: string
}

export interface MarketplaceExportResult {
  ok: boolean
  path?: string
  format?: MarketplaceExportFormat
  error?: string
  canceled?: boolean
}
