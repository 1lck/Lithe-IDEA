import { useEffect, useRef, useState } from 'react'
import type { FileNode } from '@common/types'
import './ProjectSidebar.css'

interface Props {
  root: FileNode | null
  onFileOpen: (path: string) => void
  onTreeChanged?: () => void
}

type MenuState = {
  x: number
  y: number
  node: FileNode
} | null

function fileBadge(name: string, isDirectory: boolean): { mark: string; tone: string } {
  if (isDirectory) return { mark: '', tone: 'dir' }
  const ext = name.split('.').pop()?.toLowerCase() || ''
  if (ext === 'java') return { mark: 'C', tone: 'java' }
  if (ext === 'kt' || ext === 'kts') return { mark: 'K', tone: 'kt' }
  if (ext === 'xml') return { mark: 'x', tone: 'xml' }
  if (ext === 'json') return { mark: '{}', tone: 'json' }
  if (ext === 'md') return { mark: 'M', tone: 'md' }
  if (ext === 'ts' || ext === 'tsx') return { mark: 'TS', tone: 'ts' }
  if (ext === 'js' || ext === 'jsx') return { mark: 'JS', tone: 'js' }
  if (ext === 'css' || ext === 'scss') return { mark: '#', tone: 'css' }
  if (ext === 'properties' || ext === 'yml' || ext === 'yaml') return { mark: 'P', tone: 'prop' }
  if (name === 'pom.xml') return { mark: 'm', tone: 'maven' }
  if (ext === 'class' || ext === 'jar') return { mark: 'B', tone: 'bin' }
  return { mark: '·', tone: 'file' }
}

function parentDir(p: string): string {
  const i = Math.max(p.lastIndexOf('\\'), p.lastIndexOf('/'))
  return i >= 0 ? p.slice(0, i) : p
}

function joinPath(dir: string, name: string): string {
  const sep = dir.includes('/') && !dir.includes('\\') ? '/' : '\\'
  return `${dir.replace(/[/\\]+$/, '')}${sep}${name}`
}

export function ProjectSidebar({ root, onFileOpen, onTreeChanged }: Props): JSX.Element {
  const [menu, setMenu] = useState<MenuState>(null)
  const menuRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    if (!menu) return
    const close = (e: MouseEvent): void => {
      if (!menuRef.current?.contains(e.target as Node)) setMenu(null)
    }
    const onKey = (e: KeyboardEvent): void => {
      if (e.key === 'Escape') setMenu(null)
    }
    document.addEventListener('mousedown', close)
    document.addEventListener('keydown', onKey)
    return () => {
      document.removeEventListener('mousedown', close)
      document.removeEventListener('keydown', onKey)
    }
  }, [menu])

  if (!root) return <div className="sidebar-loading">Loading…</div>

  const run = async (fn: () => Promise<void>): Promise<void> => {
    try {
      await fn()
      onTreeChanged?.()
    } catch (e: any) {
      window.alert(e?.message || String(e))
    } finally {
      setMenu(null)
    }
  }

  const newFile = (): void => {
    if (!menu) return
    const dir = menu.node.isDirectory ? menu.node.path : parentDir(menu.node.path)
    const name = window.prompt('New file name')
    if (!name?.trim()) return
    void run(() => window.api.createFile(joinPath(dir, name.trim()), { content: '' }))
  }

  const newFolder = (): void => {
    if (!menu) return
    const dir = menu.node.isDirectory ? menu.node.path : parentDir(menu.node.path)
    const name = window.prompt('New folder name')
    if (!name?.trim()) return
    void run(() => window.api.createFile(joinPath(dir, name.trim()), { directory: true }))
  }

  const rename = (): void => {
    if (!menu) return
    const next = window.prompt('Rename to', menu.node.name)
    if (!next?.trim() || next.trim() === menu.node.name) return
    const dest = joinPath(parentDir(menu.node.path), next.trim())
    void run(() => window.api.renameFile(menu.node.path, dest))
  }

  const duplicate = (): void => {
    if (!menu || menu.node.isDirectory) return
    void run(async () => {
      const data = await window.api.readFile(menu.node.path)
      if (data.binary) throw new Error('Cannot duplicate binary file')
      const base = menu.node.name
      const dot = base.lastIndexOf('.')
      const stem = dot > 0 ? base.slice(0, dot) : base
      const ext = dot > 0 ? base.slice(dot) : ''
      await window.api.createFile(joinPath(parentDir(menu.node.path), `${stem} copy${ext}`), {
        content: data.content
      })
    })
  }

  const remove = (): void => {
    if (!menu) return
    if (!window.confirm(`Delete “${menu.node.name}”?`)) return
    void run(() => window.api.deleteFile(menu.node.path))
  }

  const reveal = (): void => {
    if (!menu) return
    void window.api.revealInFolder(menu.node.path)
    setMenu(null)
  }

  return (
    <div className="project-sidebar">
      <div className="sidebar-header">
        <span>Project</span>
      </div>
      <div className="sidebar-tree">
        <div
          className="tree-root-label"
          onContextMenu={(e) => {
            e.preventDefault()
            setMenu({ x: e.clientX, y: e.clientY, node: root })
          }}
        >
          {root.name}
        </div>
        {root.children?.map((node) => (
          <TreeNode
            key={node.path}
            node={node}
            depth={0}
            onFileOpen={onFileOpen}
            onContextMenu={(e, n) => {
              e.preventDefault()
              setMenu({ x: e.clientX, y: e.clientY, node: n })
            }}
          />
        ))}
      </div>

      {menu && (
        <div
          ref={menuRef}
          className="tree-menu"
          style={{ left: menu.x, top: menu.y }}
          role="menu"
        >
          <button type="button" role="menuitem" onClick={newFile}>
            New File…
          </button>
          <button type="button" role="menuitem" onClick={newFolder}>
            New Folder…
          </button>
          <div className="tree-menu-sep" />
          <button type="button" role="menuitem" onClick={rename}>
            Rename…
          </button>
          {!menu.node.isDirectory && (
            <button type="button" role="menuitem" onClick={duplicate}>
              Duplicate
            </button>
          )}
          <button type="button" role="menuitem" onClick={reveal}>
            Reveal in Explorer
          </button>
          <div className="tree-menu-sep" />
          <button type="button" role="menuitem" className="danger" onClick={remove}>
            Delete
          </button>
        </div>
      )}
    </div>
  )
}

function TreeNode({
  node,
  depth,
  onFileOpen,
  onContextMenu
}: {
  node: FileNode
  depth: number
  onFileOpen: (p: string) => void
  onContextMenu: (e: React.MouseEvent, node: FileNode) => void
}): JSX.Element {
  const [expanded, setExpanded] = useState(depth < 1)
  const badge = fileBadge(node.name, node.isDirectory)

  if (node.isDirectory) {
    return (
      <div className="tree-dir">
        <button
          type="button"
          className="tree-row"
          style={{ paddingLeft: 8 + depth * 14 }}
          onClick={() => setExpanded(!expanded)}
          onContextMenu={(e) => onContextMenu(e, node)}
        >
          <span className={`tree-arrow ${expanded ? 'expanded' : ''}`}>▸</span>
          <span className="tree-folder" aria-hidden="true" />
          <span className="tree-label">{node.name}</span>
        </button>
        {expanded &&
          node.children?.map((child) => (
            <TreeNode
              key={child.path}
              node={child}
              depth={depth + 1}
              onFileOpen={onFileOpen}
              onContextMenu={onContextMenu}
            />
          ))}
      </div>
    )
  }

  return (
    <button
      type="button"
      className="tree-row tree-file"
      style={{ paddingLeft: 8 + depth * 14 + 14 }}
      onClick={() => onFileOpen(node.path)}
      onDoubleClick={() => onFileOpen(node.path)}
      onContextMenu={(e) => onContextMenu(e, node)}
    >
      <span className={`tree-badge tone-${badge.tone}`}>{badge.mark}</span>
      <span className="tree-label">{node.name}</span>
    </button>
  )
}
