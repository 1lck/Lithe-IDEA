/** Apply VS Code / IDEA theme contributions onto Lithe CSS variables + Monaco. */

const VS_COLOR_MAP: Record<string, string> = {
  'editor.background': '--lithe-editor',
  'editor.foreground': '--lithe-text-primary',
  'sideBar.background': '--lithe-sidebar',
  'activityBar.background': '--lithe-sidebar',
  'titleBar.activeBackground': '--lithe-titlebar',
  'statusBar.background': '--lithe-titlebar',
  'tab.activeBackground': '--lithe-active-tab',
  'tab.activeBorder': '--lithe-tab-underline',
  'focusBorder': '--lithe-accent',
  'button.background': '--lithe-accent',
  'list.activeSelectionBackground': '--lithe-selection',
  'input.background': '--lithe-input-bg',
  'input.border': '--lithe-input-border',
  'panel.border': '--lithe-panel-border',
  'editorGroupHeader.tabsBackground': '--lithe-window'
}

function normalizeHex(color: string): string | null {
  if (!color || typeof color !== 'string') return null
  let c = color.trim()
  if (c.startsWith('#')) {
    // strip alpha #RRGGBBAA
    if (c.length === 9) c = c.slice(0, 7)
    if (c.length === 5) c = `#${c[1]}${c[1]}${c[2]}${c[2]}${c[3]}${c[3]}`
    return c
  }
  return null
}

export function clearPluginTheme(): void {
  const root = document.documentElement
  root.removeAttribute('data-plugin-theme')
  for (const cssVar of Object.values(VS_COLOR_MAP)) {
    root.style.removeProperty(cssVar)
  }
  root.style.removeProperty('--lithe-window')
}

export function applyVsCodeThemeJson(themeId: string, theme: any): void {
  clearPluginTheme()
  const colors = theme?.colors || {}
  const root = document.documentElement
  root.setAttribute('data-plugin-theme', themeId)

  for (const [key, cssVar] of Object.entries(VS_COLOR_MAP)) {
    const hex = normalizeHex(colors[key])
    if (hex) root.style.setProperty(cssVar, hex)
  }

  // Keep window chrome in sync if sidebar set
  const side = normalizeHex(colors['sideBar.background'] || colors['editor.background'])
  if (side) root.style.setProperty('--lithe-window', side)

  // Dispatch for Monaco to re-theme
  window.dispatchEvent(
    new CustomEvent('lithe:plugin-theme', {
      detail: { id: themeId, kind: 'vscode', theme }
    })
  )
}

/** Very light .icls → CSS mapping for a few common option names */
export function applyIdeaIcls(themeId: string, xml: string): void {
  clearPluginTheme()
  const root = document.documentElement
  root.setAttribute('data-plugin-theme', themeId)

  const pick = (name: string): string | null => {
    const re = new RegExp(
      `<option\\s+name="${name}"[^>]*value="([^"]+)"|<value[^>]*name="${name}"[^>]*>\\s*<option[^>]*value="([^"]+)"`,
      'i'
    )
    const m = xml.match(re)
    const raw = m?.[1] || m?.[2]
    if (!raw) return null
    // IDEA often uses RRGGBB without #
    if (/^[0-9a-fA-F]{6}$/.test(raw)) return `#${raw}`
    if (/^[0-9a-fA-F]{8}$/.test(raw)) return `#${raw.slice(2)}` // skip alpha nibble variants
    return normalizeHex(raw.startsWith('#') ? raw : `#${raw}`)
  }

  const bg = pick('CONSOLE_BACKGROUND_KEY') || pick('TEXT') || pick('CaretRow')
  // TEXT is often foreground; try EDITOR_BACKGROUND style names
  const editorBg =
    pick('EDITOR_BACKGROUND') ||
    (() => {
      const m = xml.match(/name="TEXT"[\s\S]*?value="([0-9a-fA-F]{6,8})"/i)
      return m ? (m[1].length >= 6 ? `#${m[1].slice(-6)}` : null) : null
    })()

  const background = editorBg || bg
  if (background) {
    root.style.setProperty('--lithe-editor', background)
    root.style.setProperty('--lithe-window', background)
    root.style.setProperty('--lithe-sidebar', background)
  }

  window.dispatchEvent(
    new CustomEvent('lithe:plugin-theme', {
      detail: { id: themeId, kind: 'idea', xml }
    })
  )
}

const ACTIVE_THEME_KEY = 'lithe.plugin.activeTheme'

export function rememberActiveTheme(id: string | null): void {
  if (!id) localStorage.removeItem(ACTIVE_THEME_KEY)
  else localStorage.setItem(ACTIVE_THEME_KEY, id)
}

export function loadRememberedThemeId(): string | null {
  return localStorage.getItem(ACTIVE_THEME_KEY)
}
