import { useState, useEffect } from 'react'
import type { AppSettings } from '@common/types'
import './SettingsView.css'

interface Props {
  onClose: () => void
  onOpenPlugins?: () => void
}

const DEFAULT_SETTINGS: AppSettings = {
  language: 'en',
  editorFontSize: 13,
  tabWidth: 4,
  showCodeVision: true,
  autoSave: false,
  autoSaveDelay: 1.5,
  terminalShell: 'system',
  hiddenDirectories: ['.git', 'node_modules', 'target', 'build', 'dist', 'out', '.gradle'],
  hiddenFilePatterns: ['*.class', '*.jar', '.DS_Store', 'Thumbs.db']
}

export function SettingsView({ onClose, onOpenPlugins }: Props): JSX.Element {
  const [settings, setSettings] = useState<AppSettings>(DEFAULT_SETTINGS)
  const [dirty, setDirty] = useState(false)

  useEffect(() => {
    ;(window as any).electron.ipcRenderer.invoke('settings:get').then((s: AppSettings) => {
      setSettings(s)
    })
  }, [])

  const update = <K extends keyof AppSettings>(key: K, value: AppSettings[K]): void => {
    setSettings((prev) => ({ ...prev, [key]: value }))
    setDirty(true)
  }

  const save = async (): Promise<void> => {
    await (window as any).electron.ipcRenderer.invoke('settings:set', settings)
    setDirty(false)
  }

  return (
    <div className="settings-overlay" onClick={onClose}>
      <div className="settings-modal" onClick={(e) => e.stopPropagation()}>
        <div className="settings-header">
          <h2>Settings</h2>
          <button className="settings-close" onClick={onClose}>&times;</button>
        </div>
        <div className="settings-body">
          <div className="settings-group">
            <label>Language</label>
            <select value={settings.language} onChange={(e) => update('language', e.target.value as 'en' | 'zh-Hans')}>
              <option value="en">English</option>
              <option value="zh-Hans">简体中文</option>
            </select>
          </div>

          <div className="settings-group">
            <label>Editor Font Size</label>
            <input
              type="number"
              min={8}
              max={32}
              value={settings.editorFontSize}
              onChange={(e) => update('editorFontSize', Number(e.target.value))}
            />
          </div>

          <div className="settings-group">
            <label>Tab Width</label>
            <input
              type="number"
              min={2}
              max={8}
              value={settings.tabWidth}
              onChange={(e) => update('tabWidth', Number(e.target.value))}
            />
          </div>

          <div className="settings-group">
            <label>
              <input
                type="checkbox"
                checked={settings.showCodeVision}
                onChange={(e) => update('showCodeVision', e.target.checked)}
              />
              Show Code Vision (usages count above methods)
            </label>
          </div>

          <div className="settings-group">
            <label>
              <input
                type="checkbox"
                checked={settings.autoSave}
                onChange={(e) => update('autoSave', e.target.checked)}
              />
              Auto Save
            </label>
            {settings.autoSave && (
              <div className="settings-sub">
                <label>Delay (seconds)</label>
                <input
                  type="number"
                  step={0.5}
                  min={0.5}
                  max={30}
                  value={settings.autoSaveDelay}
                  onChange={(e) => update('autoSaveDelay', Number(e.target.value))}
                />
              </div>
            )}
          </div>

          <div className="settings-group">
            <label>Terminal Shell</label>
            <select value={settings.terminalShell} onChange={(e) => update('terminalShell', e.target.value as AppSettings['terminalShell'])}>
              <option value="system">System Default</option>
              <option value="powershell">PowerShell</option>
              <option value="cmd">CMD</option>
              <option value="gitbash">Git Bash</option>
            </select>
          </div>

          <div className="settings-group">
            <label>Hidden Directories (comma-separated)</label>
            <input
              value={settings.hiddenDirectories.join(', ')}
              onChange={(e) => update('hiddenDirectories', e.target.value.split(',').map((s) => s.trim()).filter(Boolean))}
            />
          </div>

          <div className="settings-group">
            <label>Hidden File Patterns (comma-separated)</label>
            <input
              value={settings.hiddenFilePatterns.join(', ')}
              onChange={(e) => update('hiddenFilePatterns', e.target.value.split(',').map((s) => s.trim()).filter(Boolean))}
            />
          </div>

          {onOpenPlugins && (
            <div className="settings-group">
              <label>Plugins</label>
              <button type="button" className="settings-link-btn" onClick={onOpenPlugins}>
                Manage VS Code &amp; IDEA plugins…
              </button>
            </div>
          )}
        </div>
        <div className="settings-footer">
          <button className="settings-save" onClick={save} disabled={!dirty}>
            Save
          </button>
          <button className="settings-restore" onClick={() => { setSettings(DEFAULT_SETTINGS); setDirty(true) }}>
            Restore Defaults
          </button>
        </div>
      </div>
    </div>
  )
}
