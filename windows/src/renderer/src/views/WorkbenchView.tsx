import { useState, useEffect, useCallback } from 'react'
import type { FileNode } from '@common/types'
import { ProjectSidebar } from '../components/ProjectSidebar'
import { EditorTabs } from '../components/EditorTabs'
import { MonacoEditor } from '../components/MonacoEditor'
import { TerminalPanel } from '../components/TerminalPanel'
import { GitPanel } from '../components/GitPanel'
import { RunPanel } from '../components/RunPanel'
import { SearchEverywhere } from '../components/SearchEverywhere'
import { SearchSidebar } from '../components/SearchSidebar'
import { LocalHistoryPanel } from '../components/LocalHistoryPanel'
import { BranchSwitcher } from '../components/BranchSwitcher'
import { ProjectSwitcher } from '../components/ProjectSwitcher'
import { DiffReviewView, type DiffTarget } from '../components/DiffReviewView'
import { MavenPanel } from '../components/MavenPanel'
import { StructurePanel } from '../components/StructurePanel'
import { ProblemsPanel } from '../components/ProblemsPanel'
import { ToolWindowHeader } from '../components/ToolWindowHeader'
import { SettingsView } from './SettingsView'
import { PluginsView } from './PluginsView'
import {
  applyIdeaIcls,
  applyVsCodeThemeJson,
  loadRememberedThemeId,
  rememberActiveTheme
} from '../plugins/applyPluginTheme'
import './WorkbenchView.css'

interface EditorTab {
  id: string
  path: string
  name: string
  content: string
  savedContent: string
  language: string
  binary?: boolean
  sizeLabel?: string
}

type SidebarTool = 'project' | 'git' | 'search' | 'structure' | 'maven' | 'problems'
type BottomTool = 'terminal' | 'run' | 'history' | 'debug' | null

interface Props {
  projectPath: string
  onCloseProject: () => void
  onOpenProject: (path: string) => void
}

const ACTIVITY: { id: SidebarTool; title: string; icon: JSX.Element }[] = [
  {
    id: 'project',
    title: 'Project',
    icon: (
      <svg viewBox="0 0 20 20" fill="none" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round">
        <path d="M3 7l7-4 7 4v6l-7 4-7-4V7z" /><path d="M3 7l7 4 7-4" /><path d="M10 11v7" />
      </svg>
    )
  },
  {
    id: 'search',
    title: 'Search (Ctrl+Shift+F)',
    icon: (
      <svg viewBox="0 0 20 20" fill="none" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round">
        <circle cx="8.5" cy="8.5" r="5.5" /><path d="M13 13l4.5 4.5" />
      </svg>
    )
  },
  {
    id: 'git',
    title: 'Git',
    icon: (
      <svg viewBox="0 0 20 20" fill="none" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round">
        <circle cx="7" cy="5" r="2" /><circle cx="13" cy="15" r="2" /><circle cx="13" cy="8" r="2" />
        <path d="M7 7v4c0 2 2 4 6 4M7 7c0 2 2 3 6 1" />
      </svg>
    )
  },
  {
    id: 'structure',
    title: 'Structure',
    icon: (
      <svg viewBox="0 0 20 20" fill="none" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round">
        <rect x="3" y="3" width="14" height="4" rx="1" /><rect x="3" y="9" width="9" height="4" rx="1" /><rect x="3" y="15" width="6" height="3" rx="1" />
      </svg>
    )
  },
  {
    id: 'maven',
    title: 'Maven',
    icon: (
      <svg viewBox="0 0 20 20" fill="none" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round">
        <path d="M4 4h12v12H4z" /><path d="M4 8h12M8 8v8" />
      </svg>
    )
  },
  {
    id: 'problems',
    title: 'Problems',
    icon: (
      <svg viewBox="0 0 20 20" fill="none" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round">
        <path d="M10 3l8 14H2L10 3z" /><path d="M10 9v3M10 14.5v.5" />
      </svg>
    )
  }
]

export function WorkbenchView({ projectPath, onCloseProject, onOpenProject }: Props): JSX.Element {
  const [tree, setTree] = useState<FileNode | null>(null)
  const [tabs, setTabs] = useState<EditorTab[]>([])
  const [activeTabId, setActiveTabId] = useState<string | null>(null)
  const [sidebarTool, setSidebarTool] = useState<SidebarTool>('project')
  const [bottomTool, setBottomTool] = useState<BottomTool>(null)
  const [searchOpen, setSearchOpen] = useState(false)
  const [settingsOpen, setSettingsOpen] = useState(false)
  const [pluginsOpen, setPluginsOpen] = useState(false)
  const [branchOpen, setBranchOpen] = useState(false)
  const [projectOpen, setProjectOpen] = useState(false)
  const [branchName, setBranchName] = useState('…')
  const [diffTarget, setDiffTarget] = useState<DiffTarget | null>(null)
  const [pluginCommands, setPluginCommands] = useState<
    Array<{ id: string; title: string; category?: string; pluginName: string }>
  >([])
  const [pluginThemes, setPluginThemes] = useState<
    Array<{ id: string; label: string; pluginName: string }>
  >([])
  const [serverUrl, setServerUrl] = useState<string | null>(null)
  const [servePort, setServePort] = useState(() => {
    const n = Number(localStorage.getItem('lithe.serve.port') || '5500')
    return Number.isFinite(n) && n >= 1 && n <= 65535 ? n : 5500
  })
  const [serveMenu, setServeMenu] = useState(false)
  const [terminalMounted, setTerminalMounted] = useState(false)

  const activeTab = tabs.find((t) => t.id === activeTabId) || null
  const projectName = tree?.name || projectPath.split(/[\\/]/).filter(Boolean).pop() || 'Lithe'

  const refreshTree = useCallback(() => {
    void window.api.scanProject(projectPath).then(setTree)
  }, [projectPath])

  useEffect(() => {
    void window.api
      .gitStatus(projectPath)
      .then((s) => setBranchName(s?.branch || 'no-git'))
      .catch(() => setBranchName('no-git'))
  }, [projectPath])

  useEffect(() => {
    setTabs([])
    setActiveTabId(null)
    setSidebarTool('project')
    setBottomTool(null)
    setBranchOpen(false)
    setProjectOpen(false)
    setDiffTarget(null)
  }, [projectPath])

  useEffect(() => {
    if (bottomTool === 'terminal') setTerminalMounted(true)
  }, [bottomTool])

  useEffect(() => {
    if (!serveMenu) return
    const close = (): void => setServeMenu(false)
    const onKey = (e: KeyboardEvent): void => {
      if (e.key === 'Escape') close()
    }
    window.addEventListener('click', close)
    window.addEventListener('keydown', onKey)
    return () => {
      window.removeEventListener('click', close)
      window.removeEventListener('keydown', onKey)
    }
  }, [serveMenu])


  useEffect(() => {
    refreshTree()
    window.api.watchStart(projectPath, 'main')
    window.api.onWatchEvent(() => {
      refreshTree()
    })
    return () => {
      window.api.watchStop('main')
      window.api.removeAllListeners('project:watch-event')
    }
  }, [projectPath, refreshTree])

  useEffect(() => {
    const sync = (): void => {
      void window.api.localServerStatus().then((s) => {
        setServerUrl(s.running && s.url ? s.url : null)
        if (s.port) setServePort(s.port)
      })
    }
    sync()
    window.addEventListener('lithe:server-changed', sync)
    return () => window.removeEventListener('lithe:server-changed', sync)
  }, [projectPath])

  const reloadPlugins = useCallback(async (): Promise<void> => {
    try {
      const contrib = await window.api.pluginContributions()
      setPluginCommands(
        contrib.commands.map((c) => ({
          id: c.id,
          title: c.title,
          category: c.category,
          pluginName: c.pluginName
        }))
      )
      setPluginThemes(
        contrib.themes.map((t) => ({ id: t.id, label: t.label, pluginName: t.pluginName }))
      )

      const remembered = loadRememberedThemeId()
      if (remembered && contrib.themeContents[remembered]) {
        const raw = contrib.themeContents[remembered]
        if (raw && typeof raw === 'object' && (raw as any).type === 'idea-icls') {
          applyIdeaIcls(remembered, String((raw as any).xml || ''))
        } else {
          applyVsCodeThemeJson(remembered, raw)
        }
      }
    } catch {
      /* plugins optional at boot */
    }
  }, [])

  useEffect(() => {
    void reloadPlugins()
  }, [reloadPlugins])

  const applyThemeById = useCallback(async (themeId: string): Promise<void> => {
    const contrib = await window.api.pluginContributions()
    const raw = contrib.themeContents[themeId]
    if (!raw) return
    if (typeof raw === 'object' && (raw as any).type === 'idea-icls') {
      applyIdeaIcls(themeId, String((raw as any).xml || ''))
    } else {
      applyVsCodeThemeJson(themeId, raw)
    }
    rememberActiveTheme(themeId)
  }, [])

  useEffect(() => {
    const onApply = (e: Event): void => {
      const id = (e as CustomEvent).detail?.id
      if (typeof id === 'string') void applyThemeById(id)
    }
    window.addEventListener('lithe:apply-plugin-theme', onApply)
    return () => window.removeEventListener('lithe:apply-plugin-theme', onApply)
  }, [applyThemeById])

  const openFile = useCallback(async (filePath: string, _line?: number) => {
    const existing = tabs.find((t) => t.path === filePath)
    if (existing) {
      setActiveTabId(existing.id)
      return
    }
    try {
      const result = await window.api.readFile(filePath)
      const name = filePath.split(/[\\/]/).pop() || 'untitled'
      if (result.binary) {
        const tab: EditorTab = {
          id: `${Date.now()}-${Math.random()}`,
          path: filePath,
          name,
          content: '',
          savedContent: '',
          language: 'plaintext',
          binary: true,
          sizeLabel: result.sizeLabel
        }
        setTabs((prev) => [...prev, tab])
        setActiveTabId(tab.id)
        return
      }
      const tab: EditorTab = {
        id: `${Date.now()}-${Math.random()}`,
        path: filePath,
        name,
        content: result.content,
        savedContent: result.content,
        language: guessLanguage(name)
      }
      setTabs((prev) => [...prev, tab])
      setActiveTabId(tab.id)
    } catch {
      const name = filePath.split(/[\\/]/).pop() || 'untitled'
      const tab: EditorTab = {
        id: `${Date.now()}-${Math.random()}`,
        path: filePath,
        name,
        content: '',
        savedContent: '',
        language: 'plaintext',
        binary: true,
        sizeLabel: undefined
      }
      setTabs((prev) => [...prev, tab])
      setActiveTabId(tab.id)
    }
  }, [tabs])

  const closeTab = useCallback((id: string) => {
    setTabs((prev) => {
      const idx = prev.findIndex((t) => t.id === id)
      const next = prev.filter((t) => t.id !== id)
      if (activeTabId === id) {
        const newActive = next[Math.min(idx, next.length - 1)]
        setActiveTabId(newActive?.id || null)
      }
      return next
    })
  }, [activeTabId])

  const updateContent = useCallback((id: string, content: string) => {
    setTabs((prev) => prev.map((t) => (t.id === id ? { ...t, content } : t)))
  }, [])

  const saveFile = useCallback(async (id: string) => {
    const tab = tabs.find((t) => t.id === id)
    if (!tab || tab.binary) return
    void window.api.localHistorySave(tab.path, tab.savedContent)
    await window.api.writeFile(tab.path, tab.content)
    setTabs((prev) => prev.map((t) => (t.id === id ? { ...t, savedContent: t.content } : t)))
  }, [tabs])

  useEffect(() => {
    const handler = (e: KeyboardEvent): void => {
      if (e.ctrlKey && e.key === 's') { e.preventDefault(); if (activeTabId) saveFile(activeTabId) }
      if (e.ctrlKey && e.shiftKey && (e.key === 'A' || e.key === 'a')) { e.preventDefault(); setSearchOpen(true) }
      if (e.ctrlKey && e.shiftKey && (e.key === 'F' || e.key === 'f')) { e.preventDefault(); setSidebarTool('search') }
      if (e.ctrlKey && e.key === ',') { e.preventDefault(); setSettingsOpen(true) }
    }
    window.addEventListener('keydown', handler)
    return () => window.removeEventListener('keydown', handler)
  }, [activeTabId, saveFile])

  const toggleBottom = (tool: BottomTool): void => {
    setBottomTool((prev) => (prev === tool ? null : tool))
  }

  const toggleLocalServer = async (portOverride?: number): Promise<void> => {
    try {
      if (serverUrl) {
        await window.api.localServerStop()
        setServerUrl(null)
      } else {
        const p = Math.min(65535, Math.max(1, Number(portOverride ?? servePort) || 5500))
        setServePort(p)
        localStorage.setItem('lithe.serve.port', String(p))
        const res = await window.api.localServerStart(projectPath, p)
        setServerUrl(res.url)
        setServePort(res.port)
        setBottomTool('terminal')
      }
      setServeMenu(false)
      window.dispatchEvent(new Event('lithe:server-changed'))
    } catch (err: any) {
      window.alert(err?.message || String(err))
    }
  }

  return (
    <div className="workbench">
      <header className="workbench-titlebar lithe-drag">
        <div className="tb-left lithe-no-drag">
          <div className="tb-anchor">
            <button
              type="button"
              className={`tb-project ${projectOpen ? 'open' : ''}`}
              title={projectPath}
              onClick={() => {
                setProjectOpen((o) => !o)
                setBranchOpen(false)
              }}
            >
              <span className="tb-logo" aria-hidden="true">
                <span>&lt;</span>L<span>&gt;</span>
              </span>
              <span className="tb-project-name">{projectName}</span>
              <i className="tb-caret" />
            </button>
            {projectOpen && (
              <ProjectSwitcher
                currentPath={projectPath}
                onOpen={onOpenProject}
                onCloseProject={onCloseProject}
                onClose={() => setProjectOpen(false)}
              />
            )}
          </div>
          <span className="tb-sep" aria-hidden="true" />
          <div className="tb-anchor">
            <button
              type="button"
              className={`tb-branch ${branchOpen ? 'open' : ''}`}
              title="Branch"
              onClick={() => {
                setBranchOpen((o) => !o)
                setProjectOpen(false)
              }}
            >
              <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round">
                <circle cx="5" cy="4" r="1.8" />
                <circle cx="11" cy="12" r="1.8" />
                <circle cx="11" cy="6" r="1.8" />
                <path d="M5 5.8v3.2c0 1.6 1.5 3 4 3M5 5.8c0 1.5 1.5 2.2 4 1" />
              </svg>
              <span className="tb-branch-name">{branchName}</span>
              <i className="tb-caret" />
            </button>
            {branchOpen && (
              <BranchSwitcher
                projectPath={projectPath}
                branchName={branchName}
                onBranchChange={setBranchName}
                onClose={() => setBranchOpen(false)}
              />
            )}
          </div>
        </div>

        <div className="tb-right lithe-no-drag">
          <button type="button" className="tb-run-chip" title={projectName}>
            <i className="leaf" aria-hidden="true" />
            <span>{projectName}</span>
            <i className="tb-caret" />
          </button>
          <div className="tb-run">
            <button type="button" className="tb-run-label" onClick={() => setBottomTool('run')}>
              Current File
            </button>
            <button
              type="button"
              className="tb-run-play"
              title="Run"
              onClick={() => setBottomTool('run')}
            >
              <svg viewBox="0 0 16 16"><path d="M4 2.5v11l9-5.5L4 2.5z" /></svg>
            </button>
          </div>
          <button
            type="button"
            className="title-action"
            title="Search Everywhere (Ctrl+Shift+A)"
            onClick={() => setSearchOpen(true)}
          >
            <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round">
              <circle cx="6.5" cy="6.5" r="4.5" /><path d="M10 10l4 4" />
            </svg>
          </button>
          <button
            type="button"
            className="title-action"
            title="Plugins"
            onClick={() => setPluginsOpen(true)}
          >
            <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round">
              <path d="M6 2v3M10 2v3M3 7h10v6a1 1 0 01-1 1H4a1 1 0 01-1-1V7z" />
              <path d="M6 11h4" />
            </svg>
          </button>
          <button
            type="button"
            className="title-action"
            title="More"
            onClick={onCloseProject}
          >
            <svg viewBox="0 0 16 16" fill="currentColor">
              <circle cx="3.5" cy="8" r="1.2" /><circle cx="8" cy="8" r="1.2" /><circle cx="12.5" cy="8" r="1.2" />
            </svg>
          </button>
        </div>
      </header>

      <div className="workbench-body">
        <nav className="activity-bar" aria-label="Tool windows">
          {ACTIVITY.map((item) => (
            <button
              key={item.id}
              type="button"
              className={sidebarTool === item.id ? 'active' : ''}
              title={item.title}
              onClick={() => setSidebarTool(item.id)}
            >
              {item.icon}
            </button>
          ))}
          <button
            type="button"
            className={bottomTool === 'terminal' ? 'active' : ''}
            title="Terminal"
            onClick={() => toggleBottom('terminal')}
          >
            <svg viewBox="0 0 20 20" fill="none" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round">
              <rect x="3" y="4" width="14" height="12" rx="1.5" />
              <path d="M6 8l3 2-3 2M10 12h4" />
            </svg>
          </button>
          <div className="activity-spacer" />
          <button type="button" title="Plugins" onClick={() => setPluginsOpen(true)}>
            <svg viewBox="0 0 20 20" fill="none" stroke="currentColor" strokeWidth="1.35" strokeLinecap="round" strokeLinejoin="round">
              <path d="M7 3v4M13 3v4M4 9h12v7a1.5 1.5 0 01-1.5 1.5h-9A1.5 1.5 0 014 16V9z" />
              <path d="M8 14h4" />
            </svg>
          </button>
          <button type="button" title="Settings (Ctrl+,)" onClick={() => setSettingsOpen(true)}>
            <svg viewBox="0 0 20 20" fill="none" stroke="currentColor" strokeWidth="1.3" strokeLinecap="round" strokeLinejoin="round">
              <circle cx="10" cy="10" r="3" />
              <path d="M16.5 10c0 .7-.1 1.3-.3 2l1.2 1.4-1.7 1.7-1.4-1.2c-.7.3-1.3.4-2 .4l-1.4 1.2-1.7-1.7 1.2-1.4c-.2-.7-.4-1.3-.4-2l-1.2-1.4 1.7-1.7 1.4 1.2c.7-.2 1.3-.3 2-.3l1.4-1.2 1.7 1.7-1.2 1.4c.2.6.3 1.3.3 1.8z" />
            </svg>
          </button>
        </nav>

        <div className="workspace-islands">
          <div className="workspace-top">
            <aside className="workbench-sidebar">
              {sidebarTool === 'project' && (
                <ProjectSidebar root={tree} onFileOpen={openFile} onTreeChanged={refreshTree} />
              )}
              {sidebarTool === 'search' && <SearchSidebar projectPath={projectPath} onOpenFile={openFile} />}
              {sidebarTool === 'git' && (
                <GitPanel
                  projectPath={projectPath}
                  onOpenDiff={(file, staged) => setDiffTarget({ path: file, staged })}
                />
              )}
              {sidebarTool === 'structure' && (
                <StructurePanel
                  filePath={activeTab?.path || null}
                  content={activeTab && !activeTab.binary ? activeTab.content : null}
                  language={activeTab?.language}
                  onMinimize={() => setSidebarTool('project')}
                />
              )}
              {sidebarTool === 'maven' && (
                <MavenPanel
                  projectPath={projectPath}
                  onMinimize={() => setSidebarTool('project')}
                  onOpenLocation={(path) => void openFile(path)}
                />
              )}
              {sidebarTool === 'problems' && (
                <ProblemsPanel onMinimize={() => setSidebarTool('project')} />
              )}
            </aside>
            <div className="workspace-split" aria-hidden="true" />
            <div className="workbench-main">
              {diffTarget ? (
                <DiffReviewView
                  projectPath={projectPath}
                  target={diffTarget}
                  onClose={() => setDiffTarget(null)}
                  onChanged={() => {
                    /* GitPanel refreshes on remount/focus via its own effects when status changes */
                  }}
                />
              ) : (
                <>
              <EditorTabs tabs={tabs} activeId={activeTabId} onSelect={setActiveTabId} onClose={closeTab} />
              <div className="workbench-editor">
                {activeTab?.binary ? (
                  <div className="binary-unavailable">
                    <div className="binary-unavailable-icon" aria-hidden="true">
                      <svg viewBox="0 0 48 48" fill="none" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round">
                        <rect x="10" y="8" width="28" height="32" rx="3" />
                        <path d="M18 18h12M18 24h12M18 30h8" />
                        <circle cx="34" cy="34" r="9" fill="var(--lithe-editor)" />
                        <path d="M34 30v5M34 38.5v.5" />
                      </svg>
                    </div>
                    <h2>Binary file</h2>
                    <p>Cannot open this file in the editor.</p>
                    <div className="binary-unavailable-meta">
                      <span>{activeTab.name}</span>
                      {activeTab.sizeLabel && <span>{activeTab.sizeLabel}</span>}
                    </div>
                  </div>
                ) : activeTab ? (
                  <MonacoEditor
                    key={activeTab.id}
                    content={activeTab.content}
                    language={activeTab.language}
                    onChange={(v) => updateContent(activeTab.id, v)}
                  />
                ) : (
                  <div className="workbench-empty">
                    <h2>Select a file to review</h2>
                    <p>Press <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>A</kbd> to search</p>
                  </div>
                )}
              </div>
                </>
              )}
            </div>
          </div>

          {(bottomTool || terminalMounted) && (
            <div className={`workbench-bottom${bottomTool ? '' : ' is-collapsed'}`}>
              {terminalMounted && (
                <div className={`bottom-pane${bottomTool === 'terminal' ? ' is-visible' : ''}`}>
                  <TerminalPanel cwd={projectPath} />
                </div>
              )}
              {bottomTool === 'run' && (
                <RunPanel
                  projectPath={projectPath}
                  onMinimize={() => setBottomTool(null)}
                  onOpenLocation={(path) => void openFile(path)}
                />
              )}
              {bottomTool === 'history' && (
                <LocalHistoryPanel
                  filePath={activeTab?.path || null}
                  onRestored={(path, content) => {
                    setTabs((prev) =>
                      prev.map((t) =>
                        t.path === path ? { ...t, content, savedContent: content } : t
                      )
                    )
                  }}
                />
              )}
              {bottomTool === 'debug' && (
                <div className="debug-panel-stub">
                  <ToolWindowHeader
                    title="Debug"
                    subtitle="JDWP"
                    onMinimize={() => setBottomTool(null)}
                    icon={
                      <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.3">
                        <circle cx="8" cy="8" r="5.5" />
                        <path d="M8 5.5v3l2 1.2" />
                      </svg>
                    }
                  />
                  <div className="debug-stub-body">
                    <strong>Debug tool window</strong>
                    <p>
                      Layout matches macOS JavaDebugView. Breakpoints, threads, and variables will connect when the
                      JDWP session host is ported.
                    </p>
                  </div>
                </div>
              )}
            </div>
          )}
        </div>
      </div>

      <footer className="workbench-statusbar">
        <div className="status-crumbs">
          {activeTab ? (
            activeTab.path.split(/[\\/]/).filter(Boolean).slice(-4).map((part, i) => (
              <span key={`${part}-${i}`}>
                {i > 0 && <span className="sep"> › </span>}
                {part}
              </span>
            ))
          ) : (
            <span>{projectName}</span>
          )}
        </div>
        <button type="button" className={bottomTool === 'terminal' ? 'active' : ''} onClick={() => toggleBottom('terminal')}>Terminal</button>
        <button type="button" className={bottomTool === 'run' ? 'active' : ''} onClick={() => toggleBottom('run')}>Run</button>
        <button type="button" className={bottomTool === 'debug' ? 'active' : ''} onClick={() => toggleBottom('debug')}>Debug</button>
        <button type="button" className={bottomTool === 'history' ? 'active' : ''} onClick={() => toggleBottom('history')}>History</button>
        <div className="status-serve">
          {serverUrl ? (
            <button
              type="button"
              className="active"
              title={serverUrl}
              onClick={() => void toggleLocalServer()}
            >
              Serve ● :{servePort}
            </button>
          ) : (
            <>
              <button
                type="button"
                title="Start local server"
                onClick={(e) => {
                  e.stopPropagation()
                  setServeMenu((v) => !v)
                }}
              >
                Serve
              </button>
              {serveMenu && (
                <div
                  className="serve-pop lithe-no-drag"
                  onClick={(e) => e.stopPropagation()}
                  onMouseDown={(e) => e.stopPropagation()}
                >
                  <label>
                    Port
                    <input
                      type="number"
                      min={1}
                      max={65535}
                      value={servePort}
                      onChange={(e) => setServePort(Number(e.target.value) || 5500)}
                      autoFocus
                    />
                  </label>
                  <button type="button" className="serve-go" onClick={() => void toggleLocalServer()}>
                    Start
                  </button>
                </div>
              )}
            </>
          )}
        </div>
        <span className="status-spacer" />
        <span className="status-meta">UTF-8</span>
        <span className="status-meta">4 spaces</span>
        <button type="button" className="status-close" onClick={onCloseProject}>Close</button>
      </footer>
      {searchOpen && (
        <SearchEverywhere
          projectPath={projectPath}
          onClose={() => setSearchOpen(false)}
          onOpenFile={(p, line) => openFile(p, line)}
          extraActions={[
            ...pluginThemes.map((t) => ({
              id: `theme:${t.id}`,
              label: `Theme: ${t.label}`,
              preview: t.pluginName
            })),
            ...pluginCommands.slice(0, 40).map((c) => ({
              id: `cmd:${c.id}`,
              label: c.title,
              preview: c.pluginName
            }))
          ]}
          onAction={(actionId) => {
            if (actionId === 'settings') setSettingsOpen(true)
            else if (actionId === 'plugins') setPluginsOpen(true)
            else if (actionId === 'terminal') toggleBottom('terminal')
            else if (actionId === 'search-files') setSidebarTool('search')
            else if (actionId === 'close-project') onCloseProject()
            else if (actionId.startsWith('theme:')) void applyThemeById(actionId.slice(6))
            else if (actionId.startsWith('cmd:')) {
              // Plugin commands are catalogued; full VS Code/IDEA hosts are not executed
              window.alert(`Plugin command “${actionId.slice(4)}” is registered but not executed in Lithe’s host.`)
            }
          }}
        />
      )}
      {settingsOpen && (
        <SettingsView
          onClose={() => setSettingsOpen(false)}
          onOpenPlugins={() => {
            setSettingsOpen(false)
            setPluginsOpen(true)
          }}
        />
      )}
      {pluginsOpen && (
        <PluginsView
          onClose={() => setPluginsOpen(false)}
          onPluginsChanged={() => void reloadPlugins()}
        />
      )}
    </div>
  )
}

function PlaceholderPanel({ title, desc }: { title: string; desc: string }): JSX.Element {
  return (
    <div className="lithe-placeholder">
      <div className="lithe-panel-header">{title}</div>
      <div className="lithe-placeholder-body">{desc}</div>
    </div>
  )
}

function guessLanguage(name: string): string {
  const ext = name.split('.').pop()?.toLowerCase() || ''
  const map: Record<string, string> = {
    java: 'java', kt: 'kotlin', kts: 'kotlin', ts: 'typescript', tsx: 'typescript',
    js: 'javascript', jsx: 'javascript', json: 'json', xml: 'xml', yml: 'yaml', yaml: 'yaml',
    md: 'markdown', txt: 'plaintext', swift: 'swift', py: 'python', rs: 'rust', go: 'go',
    c: 'c', cpp: 'cpp', h: 'cpp', html: 'html', css: 'css', scss: 'scss',
    sh: 'shell', bat: 'bat', ps1: 'powershell', toml: 'ini', gradle: 'java', properties: 'ini'
  }
  return map[ext] || 'plaintext'
}
