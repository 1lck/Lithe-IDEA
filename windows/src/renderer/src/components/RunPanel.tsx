import { useState, useEffect, useRef, useCallback } from 'react'
import type { JdkInfo, MavenModule } from '@common/types'
import { ToolWindowHeader } from './ToolWindowHeader'
import { OutputTextView } from './OutputTextView'
import './RunPanel.css'

interface Props {
  projectPath: string
  onMinimize?: () => void
  onOpenLocation?: (path: string, line: number) => void
}

export function RunPanel({ projectPath, onMinimize, onOpenLocation }: Props): JSX.Element {
  const [jdks, setJdks] = useState<JdkInfo[]>([])
  const [selectedJdk, setSelectedJdk] = useState('')
  const [mavenPath, setMavenPath] = useState<string | null>(null)
  const [modules, setModules] = useState<MavenModule[]>([])
  const [mainClass, setMainClass] = useState('')
  const [classpath, setClasspath] = useState('')
  const [output, setOutput] = useState('')
  const [running, setRunning] = useState(false)
  const [exitOk, setExitOk] = useState<boolean | null>(null)
  const runId = useRef(`run-${Date.now()}`)

  useEffect(() => {
    void window.api.discoverJdks().then((list) => {
      setJdks(list)
      if (list[0]) setSelectedJdk(list[0].path)
    })
    void window.api.discoverMaven(projectPath).then(setMavenPath)
    void window.api.mavenScanModules(projectPath).then(setModules)
  }, [projectPath])

  useEffect(() => {
    const id = runId.current
    window.api.onJavaOutput((data: any) => {
      if (data.id === id) setOutput((prev) => prev + data.data)
    })
    window.api.onJavaExit((data: any) => {
      if (data.id === id) {
        setOutput((prev) => prev + `\n[Process exited with code ${data.code}]\n`)
        setRunning(false)
        setExitOk(data.code === 0)
      }
    })
    return () => {
      /* keep process listeners — Run/Maven panels may share channels */
    }
  }, [])

  const runJava = useCallback(() => {
    if (!selectedJdk || !mainClass) return
    setOutput('')
    setRunning(true)
    setExitOk(null)
    void window.api.javaRun(runId.current, {
      jdkPath: selectedJdk,
      mainClass,
      classpath: classpath || projectPath,
      cwd: projectPath
    })
  }, [selectedJdk, mainClass, classpath, projectPath])

  const runMaven = useCallback(
    (goals: string[]) => {
      if (!mavenPath) return
      setOutput('')
      setRunning(true)
      setExitOk(null)
      void window.api.mavenRun(runId.current, {
        mavenPath,
        goals,
        cwd: projectPath,
        jdkPath: selectedJdk
      })
    },
    [mavenPath, projectPath, selectedJdk]
  )

  return (
    <div className="run-panel">
      <ToolWindowHeader
        title="Run"
        subtitle={mainClass || 'Current File'}
        onMinimize={onMinimize}
        icon={
          <svg viewBox="0 0 16 16">
            <path d="M4 2.5v11l9-5.5L4 2.5z" fill="currentColor" />
          </svg>
        }
      >
        {running ? <span className="twh-chip run">Running</span> : null}
        {exitOk === true ? <span className="twh-chip ok">Finished</span> : null}
        {exitOk === false ? <span className="twh-chip err">Failed</span> : null}
        <button
          type="button"
          className="twh-btn"
          title="Run"
          disabled={running || !selectedJdk || !mainClass}
          onClick={runJava}
        >
          ▶
        </button>
        <button
          type="button"
          className="twh-btn"
          title="Clear"
          onClick={() => {
            setOutput('')
            setExitOk(null)
          }}
        >
          ⌫
        </button>
      </ToolWindowHeader>

      <div className="run-body">
        <aside className="run-config">
          <label>JDK</label>
          <select value={selectedJdk} onChange={(e) => setSelectedJdk(e.target.value)}>
            {jdks.length === 0 && <option value="">No JDK detected</option>}
            {jdks.map((j) => (
              <option key={j.path} value={j.path}>
                {j.version} — {j.path}
              </option>
            ))}
          </select>

          <label>Main Class</label>
          <input
            value={mainClass}
            onChange={(e) => setMainClass(e.target.value)}
            placeholder="com.example.Main"
          />

          <label>Classpath (optional)</label>
          <input
            value={classpath}
            onChange={(e) => setClasspath(e.target.value)}
            placeholder={projectPath}
          />

          <div className="run-buttons">
            <button
              type="button"
              className="run-btn"
              onClick={runJava}
              disabled={running || !selectedJdk || !mainClass}
            >
              ▶ Run
            </button>
            {mavenPath && (
              <>
                <button
                  type="button"
                  className="run-btn-secondary"
                  onClick={() => runMaven(['clean', 'compile'])}
                  disabled={running}
                >
                  mvn compile
                </button>
                <button
                  type="button"
                  className="run-btn-secondary"
                  onClick={() => runMaven(['test'])}
                  disabled={running}
                >
                  mvn test
                </button>
                <button
                  type="button"
                  className="run-btn-secondary"
                  onClick={() => runMaven(['spring-boot:run'])}
                  disabled={running}
                >
                  spring-boot:run
                </button>
              </>
            )}
          </div>

          <div className="run-info">
            <span>Maven: {mavenPath || 'not found'}</span>
            <span>Modules: {modules.length}</span>
          </div>
        </aside>
        <OutputTextView
          output={output}
          emptyMessage="Configure and run to see output"
          onOpenLocation={onOpenLocation}
        />
      </div>
    </div>
  )
}
