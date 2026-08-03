import { useState, useEffect } from 'react'
import { WelcomeView } from './views/WelcomeView'
import { WorkbenchView } from './views/WorkbenchView'
import type { RecentProject } from '@common/types'

export function App(): JSX.Element {
  const [projectPath, setProjectPath] = useState<string | null>(null)
  const [recentProjects, setRecentProjects] = useState<RecentProject[]>([])

  useEffect(() => {
    window.api.recentList().then(setRecentProjects)
  }, [])

  const openProject = async (path?: string): Promise<void> => {
    let dir: string | null | undefined = path
    if (!dir) {
      dir = await window.api.openProjectDialog()
      if (!dir) return
    }
    await window.api.recentAdd(dir)
    setProjectPath(dir)
    window.api.recentList().then(setRecentProjects)
  }

  const closeProject = (): void => {
    setProjectPath(null)
    window.api.recentList().then(setRecentProjects)
  }

  if (projectPath) {
    return (
      <WorkbenchView
        projectPath={projectPath}
        onCloseProject={closeProject}
        onOpenProject={(path) => void openProject(path)}
      />
    )
  }

  return (
    <WelcomeView
      recentProjects={recentProjects}
      onOpenProject={openProject}
      onRemoveRecent={async (p) => {
        const updated = await window.api.recentRemove(p)
        setRecentProjects(updated)
      }}
    />
  )
}
