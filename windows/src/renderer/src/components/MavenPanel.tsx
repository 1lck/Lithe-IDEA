import { useCallback, useEffect, useState } from 'react'
import type { MavenModule } from '@common/types'
import { ToolWindowHeader } from './ToolWindowHeader'
import { OutputTextView } from './OutputTextView'
import './MavenPanel.css'

interface Props {
  projectPath: string
  onMinimize?: () => void
  onOpenLocation?: (path: string, line: number) => void
}

const LIFECYCLE = ['clean', 'validate', 'compile', 'test', 'package', 'verify', 'install', 'deploy'] as const

export function MavenPanel({ projectPath, onMinimize, onOpenLocation }: Props): JSX.Element {
  const [modules, setModules] = useState<MavenModule[]>([])
  const [mavenPath, setMavenPath] = useState<string | null>(null)
  const [jdk, setJdk] = useState('')
  const [output, setOutput] = useState('')
  const [running, setRunning] = useState(false)
  const [exitOk, setExitOk] = useState<boolean | null>(null)
  const [expanded, setExpanded] = useState(true)
  const runId = `maven-${projectPath}`

  const refresh = useCallback(async () => {
    const [mods, mvn, jdks] = await Promise.all([
      window.api.mavenScanModules(projectPath),
      window.api.discoverMaven(projectPath),
      window.api.discoverJdks()
    ])
    setModules(mods)
    setMavenPath(mvn)
    if (jdks[0]) setJdk(jdks[0].path)
  }, [projectPath])

  useEffect(() => {
    void refresh()
  }, [refresh])

  useEffect(() => {
    window.api.onJavaOutput((data: any) => {
      if (data.id === runId) setOutput((p) => p + data.data)
    })
    window.api.onJavaExit((data: any) => {
      if (data.id === runId) {
        setRunning(false)
        setExitOk(data.code === 0)
        setOutput((p) => p + `\n[Process exited with code ${data.code}]\n`)
      }
    })
    return () => {
      /* shared listeners managed carefully — leave for RunPanel coexistence */
    }
  }, [runId])

  const runGoals = async (goals: string[], cwd?: string): Promise<void> => {
    if (!mavenPath) return
    setOutput('')
    setRunning(true)
    setExitOk(null)
    await window.api.mavenRun(runId, {
      mavenPath,
      goals,
      cwd: cwd || projectPath,
      jdkPath: jdk
    })
  }

  const projectName = projectPath.split(/[\\/]/).filter(Boolean).pop() || 'Project'

  return (
    <div className="maven-panel">
      <ToolWindowHeader
        title="Maven"
        subtitle={projectName}
        onMinimize={onMinimize}
        icon={
          <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.3">
            <path d="M3 3h10v10H3z" />
            <path d="M3 7h10M7 7v6" />
          </svg>
        }
      >
        {running ? <span className="twh-chip run">Running</span> : null}
        {exitOk === true ? <span className="twh-chip ok">OK</span> : null}
        {exitOk === false ? <span className="twh-chip err">Failed</span> : null}
        <button type="button" className="twh-btn" title="Refresh" onClick={() => void refresh()}>
          ↻
        </button>
        <button
          type="button"
          className="twh-btn"
          title="Clear output"
          onClick={() => {
            setOutput('')
            setExitOk(null)
          }}
        >
          ⌫
        </button>
      </ToolWindowHeader>

      <div className="maven-body">
        <aside className="maven-tree">
          <button type="button" className="maven-root" onClick={() => setExpanded((e) => !e)}>
            <span className={`maven-chev ${expanded ? 'open' : ''}`}>▸</span>
            <strong>{projectName}</strong>
          </button>
          {expanded && (
            <>
              <div className="maven-section">Lifecycle</div>
              {LIFECYCLE.map((phase) => (
                <button
                  key={phase}
                  type="button"
                  className="maven-goal"
                  disabled={running || !mavenPath}
                  onClick={() => void runGoals([phase])}
                >
                  <span>{phase}</span>
                  <em>▶</em>
                </button>
              ))}
              {modules.length > 0 && <div className="maven-section">Modules</div>}
              {modules.map((m) => (
                <div key={m.path} className="maven-mod">
                  <div className="maven-mod-name">{m.artifactId || m.name}</div>
                  <div className="maven-mod-actions">
                    {(['compile', 'test', 'package'] as const).map((g) => (
                      <button
                        key={g}
                        type="button"
                        disabled={running || !mavenPath}
                        onClick={() => void runGoals([g], m.path)}
                      >
                        {g}
                      </button>
                    ))}
                  </div>
                </div>
              ))}
              {!mavenPath && <div className="maven-hint">Maven not found on PATH / MAVEN_HOME</div>}
            </>
          )}
        </aside>
        <section className="maven-out">
          <div className="maven-out-head">Build Output</div>
          <OutputTextView
            output={output}
            emptyMessage="Run a lifecycle phase or module goal"
            onOpenLocation={onOpenLocation}
          />
        </section>
      </div>
    </div>
  )
}
