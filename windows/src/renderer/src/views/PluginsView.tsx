import { useCallback, useEffect, useMemo, useState } from 'react'
import type {
  MarketplacePlugin,
  MarketplaceVersion,
  PluginInfo,
  PluginKind
} from '@common/types'
import { VersionPicker } from '../components/VersionPicker'
import './PluginsView.css'

interface Props {
  onClose: () => void
  onPluginsChanged?: () => void
}

type Tab = 'installed' | 'marketplace'
type MarketFilter = 'all' | 'vscode' | 'idea'

function kindLabel(kind: PluginKind): string {
  if (kind === 'vscode') return 'VS Code'
  if (kind === 'idea') return 'IDEA'
  return 'Lithe'
}

function exportLabel(kind: PluginKind): string {
  if (kind === 'vscode') return 'Export .vsix…'
  if (kind === 'idea') return 'Export .zip…'
  return 'Export…'
}

function compatTone(c: PluginInfo['compatibility']): string {
  if (c === 'full') return 'full'
  if (c === 'partial') return 'partial'
  return 'meta'
}

function marketKey(item: MarketplacePlugin): string {
  return `${item.kind}:${item.id}`
}

function formatBytes(n?: number): string {
  if (typeof n !== 'number' || !Number.isFinite(n) || n <= 0) return ''
  if (n < 1024) return `${n} B`
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`
  return `${(n / (1024 * 1024)).toFixed(1)} MB`
}

export function PluginsView({ onClose, onPluginsChanged }: Props): JSX.Element {
  const [tab, setTab] = useState<Tab>('installed')
  const [installed, setInstalled] = useState<PluginInfo[]>([])
  const [query, setQuery] = useState('')
  const [marketQuery, setMarketQuery] = useState('theme')
  const [marketFilter, setMarketFilter] = useState<MarketFilter>('all')
  const [market, setMarket] = useState<MarketplacePlugin[]>([])
  const [busy, setBusy] = useState(false)
  const [status, setStatus] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [selectedId, setSelectedId] = useState<string | null>(null)
  const [marketSelectedKey, setMarketSelectedKey] = useState<string | null>(null)
  const [versions, setVersions] = useState<MarketplaceVersion[]>([])
  const [versionBusy, setVersionBusy] = useState(false)
  const [pickedVersion, setPickedVersion] = useState('')
  const [pickedUpdateId, setPickedUpdateId] = useState('')
  const [pickedDownloadUrl, setPickedDownloadUrl] = useState('')

  const refresh = useCallback(async (): Promise<void> => {
    const list = await window.api.pluginList()
    setInstalled(list)
    onPluginsChanged?.()
  }, [onPluginsChanged])

  useEffect(() => {
    void refresh().catch((e) => setError(String(e?.message || e)))
  }, [refresh])

  const filteredInstalled = useMemo(() => {
    const q = query.trim().toLowerCase()
    if (!q) return installed
    return installed.filter(
      (p) =>
        p.name.toLowerCase().includes(q) ||
        p.id.toLowerCase().includes(q) ||
        p.publisher.toLowerCase().includes(q) ||
        p.description.toLowerCase().includes(q)
    )
  }, [installed, query])

  const selected = installed.find((p) => p.id === selectedId) || filteredInstalled[0] || null

  const marketSelected =
    market.find((m) => marketKey(m) === marketSelectedKey) || market[0] || null

  const searchMarket = async (): Promise<void> => {
    setBusy(true)
    setError(null)
    setStatus('Searching marketplace…')
    try {
      const results = await window.api.pluginSearchMarket(marketFilter, marketQuery)
      setMarket(results)
      setMarketSelectedKey(results[0] ? marketKey(results[0]) : null)
      setStatus(`${results.length} results`)
    } catch (e: any) {
      setError(e?.message || String(e))
      setStatus(null)
      setMarket([])
      setMarketSelectedKey(null)
    } finally {
      setBusy(false)
    }
  }

  useEffect(() => {
    if (tab === 'marketplace') {
      void searchMarket()
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [tab, marketFilter])

  useEffect(() => {
    if (!marketSelected) {
      setVersions([])
      setPickedVersion('')
      setPickedUpdateId('')
      setPickedDownloadUrl('')
      return
    }
    let cancelled = false
    setVersionBusy(true)
    setVersions([])
    setPickedVersion(marketSelected.version || '')
    setPickedUpdateId('')
    setPickedDownloadUrl('')
    void window.api
      .pluginListVersions(marketSelected.kind, marketSelected.id, {
        namespace: marketSelected.namespace || '',
        name: marketSelected.extensionName || '',
        marketId: marketSelected.marketId || marketSelected.id
      })
      .then((list) => {
        if (cancelled) return
        setVersions(list)
        if (list[0]) {
          setPickedVersion(list[0].version)
          setPickedUpdateId(list[0].updateId || '')
          setPickedDownloadUrl(list[0].downloadUrl || '')
        }
      })
      .catch((e) => {
        if (!cancelled) setError(e?.message || String(e))
      })
      .finally(() => {
        if (!cancelled) setVersionBusy(false)
      })
    return () => {
      cancelled = true
    }
  }, [marketSelected?.kind, marketSelected?.id, marketSelected?.marketId])

  const installOpts = (item: MarketplacePlugin): Record<string, string> => {
    const opts: Record<string, string> = {
      namespace: item.namespace || '',
      name: item.extensionName || '',
      marketId: item.marketId || item.id
    }
    if (pickedVersion) opts.version = pickedVersion
    if (pickedUpdateId) opts.updateId = pickedUpdateId
    if (pickedDownloadUrl) opts.downloadUrl = pickedDownloadUrl
    return opts
  }

  const installDisk = async (): Promise<void> => {
    setBusy(true)
    setError(null)
    try {
      const info = await window.api.pluginInstallDialog()
      if (info) {
        setStatus(`Installed ${info.name}`)
        setTab('installed')
        setSelectedId(info.id)
        await refresh()
      }
    } catch (e: any) {
      setError(e?.message || String(e))
    } finally {
      setBusy(false)
    }
  }

  const toggle = async (p: PluginInfo): Promise<void> => {
    setBusy(true)
    try {
      const list = await window.api.pluginSetEnabled(p.id, !p.enabled)
      setInstalled(list)
      onPluginsChanged?.()
      setStatus(`${p.name} ${p.enabled ? 'disabled' : 'enabled'}`)
    } catch (e: any) {
      setError(e?.message || String(e))
    } finally {
      setBusy(false)
    }
  }

  const uninstall = async (p: PluginInfo): Promise<void> => {
    if (!window.confirm(`Uninstall “${p.name}”?`)) return
    setBusy(true)
    try {
      const list = await window.api.pluginUninstall(p.id)
      setInstalled(list)
      setSelectedId(null)
      onPluginsChanged?.()
      setStatus(`Uninstalled ${p.name}`)
    } catch (e: any) {
      setError(e?.message || String(e))
    } finally {
      setBusy(false)
    }
  }

  const installMarketItem = async (item: MarketplacePlugin): Promise<void> => {
    setBusy(true)
    setError(null)
    const ver = pickedVersion ? ` v${pickedVersion}` : ''
    setStatus(`Installing ${item.name}${ver}…`)
    try {
      const info = await window.api.pluginInstallMarket(item.kind, item.id, installOpts(item))
      setStatus(`Installed ${info.name} v${info.version}`)
      setTab('installed')
      setSelectedId(info.id)
      await refresh()
    } catch (e: any) {
      setError(e?.message || String(e))
      setStatus(null)
    } finally {
      setBusy(false)
    }
  }

  const exportMarketItem = async (item: MarketplacePlugin): Promise<void> => {
    setBusy(true)
    setError(null)
    setStatus(`Exporting ${item.name}${pickedVersion ? ` v${pickedVersion}` : ''}…`)
    try {
      const res = await window.api.pluginExportMarket(item.kind, item.id, installOpts(item))
      if (res.canceled) {
        setStatus(null)
        return
      }
      if (!res.ok) throw new Error(res.error || 'Export failed')
      setStatus(`Exported ${res.format?.toUpperCase()} → ${res.path}`)
    } catch (e: any) {
      setError(e?.message || String(e))
      setStatus(null)
    } finally {
      setBusy(false)
    }
  }

  const exportInstalled = async (p: PluginInfo): Promise<void> => {
    setBusy(true)
    setError(null)
    setStatus(`Exporting ${p.name}…`)
    try {
      const res = await window.api.pluginExportInstalled(p.id)
      if (res.canceled) {
        setStatus(null)
        return
      }
      if (!res.ok) throw new Error(res.error || 'Export failed')
      setStatus(`Exported ${res.format?.toUpperCase()} → ${res.path}`)
    } catch (e: any) {
      setError(e?.message || String(e))
      setStatus(null)
    } finally {
      setBusy(false)
    }
  }

  const onPickVersion = (version: string, item?: MarketplaceVersion): void => {
    setPickedVersion(version)
    const hit = item || versions.find((v) => v.version === version)
    setPickedUpdateId(hit?.updateId || '')
    setPickedDownloadUrl(hit?.downloadUrl || '')
  }

  const pickedMeta = versions.find((v) => v.version === pickedVersion)

  return (
    <div className="plugins-overlay" onClick={onClose}>
      <div className="plugins-shell plugins-shell--wide" onClick={(e) => e.stopPropagation()}>
        <header className="plugins-header">
          <div className="plugins-title-block">
            <h2>Plugins</h2>
            <p>Browse versions · Install · Export .vsix / .zip for VS Code &amp; IDEA</p>
          </div>
          <div className="plugins-header-actions">
            <button type="button" className="plugins-btn" disabled={busy} onClick={() => void installDisk()}>
              Install from Disk…
            </button>
            <button type="button" className="plugins-btn ghost" onClick={() => void window.api.pluginOpenFolder()}>
              Open Folder
            </button>
            <button type="button" className="plugins-close" onClick={onClose} aria-label="Close">
              ×
            </button>
          </div>
        </header>

        <nav className="plugins-tabs">
          <button type="button" className={tab === 'installed' ? 'active' : ''} onClick={() => setTab('installed')}>
            Installed
            <span>{installed.length}</span>
          </button>
          <button type="button" className={tab === 'marketplace' ? 'active' : ''} onClick={() => setTab('marketplace')}>
            Marketplace
          </button>
        </nav>

        {(status || error) && (
          <div className={`plugins-banner ${error ? 'err' : ''}`}>{error || status}</div>
        )}

        {tab === 'installed' ? (
          <div className="plugins-body">
            <aside className="plugins-list-pane">
              <div className="plugins-search">
                <input
                  value={query}
                  onChange={(e) => setQuery(e.target.value)}
                  placeholder="Search installed…"
                />
              </div>
              <div className="plugins-list">
                {filteredInstalled.length === 0 && (
                  <div className="plugins-empty">No plugins installed yet. Browse Marketplace or Install from Disk.</div>
                )}
                {filteredInstalled.map((p) => (
                  <button
                    key={p.id}
                    type="button"
                    className={`plugins-row ${selected?.id === p.id ? 'active' : ''} ${p.enabled ? '' : 'off'}`}
                    onClick={() => setSelectedId(p.id)}
                  >
                    <span className={`plugins-kind ${p.kind}`}>{kindLabel(p.kind)}</span>
                    <span className="plugins-row-main">
                      <span className="plugins-row-name">{p.name}</span>
                      <span className="plugins-row-meta">{p.publisher} · {p.version}</span>
                    </span>
                    <span className={`plugins-dot ${p.enabled ? 'on' : ''}`} />
                  </button>
                ))}
              </div>
            </aside>

            <section className="plugins-detail">
              {selected ? (
                <>
                  <div className="plugins-detail-head">
                    <span className={`plugins-kind lg ${selected.kind}`}>{kindLabel(selected.kind)}</span>
                    <div>
                      <h3>{selected.name}</h3>
                      <div className="plugins-detail-sub">
                        {selected.publisher} · v{selected.version} · {selected.id}
                      </div>
                    </div>
                  </div>
                  <p className="plugins-desc">{selected.description || 'No description.'}</p>
                  <div className={`plugins-compat ${compatTone(selected.compatibility)}`}>
                    <strong>
                      {selected.compatibility === 'full'
                        ? 'Full support'
                        : selected.compatibility === 'partial'
                          ? 'Partial support'
                          : 'Metadata only'}
                    </strong>
                    <span>{selected.compatibilityNote}</span>
                  </div>
                  <div className="plugins-contrib">
                    <div><em>{selected.contributes.themes.length}</em> themes</div>
                    <div><em>{selected.contributes.commands.length}</em> commands</div>
                    <div><em>{selected.contributes.snippets.length}</em> snippets</div>
                    <div><em>{selected.contributes.languages.length}</em> languages</div>
                    <div><em>{selected.contributes.views?.length || 0}</em> sidebar views</div>
                  </div>
                  {(selected.contributes.views?.length || 0) > 0 && (
                    <div className="plugins-theme-list">
                      <div className="plugins-theme-label">Sidebar / tool windows</div>
                      <ul className="plugins-view-list">
                        {(selected.contributes.views || []).map((v) => (
                          <li key={v.id}>
                            {v.title}
                            {v.synthetic ? ' (placeholder)' : ''}
                            {v.location === 'panel' ? ' · panel' : ''}
                          </li>
                        ))}
                      </ul>
                    </div>
                  )}
                  {selected.contributes.themes.length > 0 && (
                    <div className="plugins-theme-list">
                      <div className="plugins-theme-label">Themes</div>
                      {selected.contributes.themes.map((t) => (
                        <button
                          key={t.id}
                          type="button"
                          className="plugins-btn"
                          disabled={busy || !selected.enabled}
                          onClick={() => {
                            window.dispatchEvent(new CustomEvent('lithe:apply-plugin-theme', { detail: { id: t.id } }))
                            setStatus(`Applied theme: ${t.label}`)
                          }}
                        >
                          Apply “{t.label}”
                        </button>
                      ))}
                    </div>
                  )}
                  <div className="plugins-detail-actions">
                    <button type="button" className="plugins-btn primary" disabled={busy} onClick={() => void toggle(selected)}>
                      {selected.enabled ? 'Disable' : 'Enable'}
                    </button>
                    <button type="button" className="plugins-btn" disabled={busy} onClick={() => void exportInstalled(selected)}>
                      {exportLabel(selected.kind)}
                    </button>
                    <button type="button" className="plugins-btn danger" disabled={busy} onClick={() => void uninstall(selected)}>
                      Uninstall
                    </button>
                  </div>
                </>
              ) : (
                <div className="plugins-empty pad">Select a plugin</div>
              )}
            </section>
          </div>
        ) : (
          <div className="plugins-market plugins-market--split">
            <div className="plugins-market-bar">
              <div className="plugins-filters">
                {(['all', 'vscode', 'idea'] as MarketFilter[]).map((f) => (
                  <button
                    key={f}
                    type="button"
                    className={marketFilter === f ? 'active' : ''}
                    onClick={() => setMarketFilter(f)}
                  >
                    {f === 'all' ? 'All' : f === 'vscode' ? 'VS Code (Open VSX)' : 'IDEA (JetBrains)'}
                  </button>
                ))}
              </div>
              <div className="plugins-market-search">
                <input
                  value={marketQuery}
                  onChange={(e) => setMarketQuery(e.target.value)}
                  onKeyDown={(e) => e.key === 'Enter' && void searchMarket()}
                  placeholder="Search themes, languages, tools…"
                />
                <button type="button" className="plugins-btn primary" disabled={busy} onClick={() => void searchMarket()}>
                  Search
                </button>
              </div>
            </div>

            <div className="plugins-market-body">
              <aside className="plugins-list-pane">
                <div className="plugins-list">
                  {busy && market.length === 0 && (
                    <div className="plugins-empty" aria-busy>
                      Searching marketplace…
                    </div>
                  )}
                  {!busy && market.length === 0 && (
                    <div className="plugins-empty">No results. Try another query.</div>
                  )}
                  {market.map((item) => {
                    const key = marketKey(item)
                    return (
                      <button
                        key={key}
                        type="button"
                        className={`plugins-row ${marketSelected && marketKey(marketSelected) === key ? 'active' : ''}`}
                        onClick={() => setMarketSelectedKey(key)}
                      >
                        <span className={`plugins-kind ${item.kind}`}>{kindLabel(item.kind)}</span>
                        <span className="plugins-row-main">
                          <span className="plugins-row-name">{item.name}</span>
                          <span className="plugins-row-meta">
                            {String(item.publisher || '')}
                            {item.version ? ` · ${item.version}` : ''}
                          </span>
                        </span>
                        {item.installed && <span className="plugins-installed-tag">In</span>}
                      </button>
                    )
                  })}
                </div>
              </aside>

              <section className="plugins-detail">
                {marketSelected ? (
                  <>
                    <div className="plugins-detail-head">
                      <span className={`plugins-kind lg ${marketSelected.kind}`}>
                        {kindLabel(marketSelected.kind)}
                      </span>
                      <div>
                        <h3>{marketSelected.name}</h3>
                        <div className="plugins-detail-sub">
                          {String(marketSelected.publisher || '')}
                          {typeof marketSelected.downloads === 'number'
                            ? ` · ${marketSelected.downloads.toLocaleString()} downloads`
                            : ''}
                          {' · '}
                          {marketSelected.id}
                        </div>
                      </div>
                    </div>
                    <p className="plugins-desc">{marketSelected.description || 'No description.'}</p>

                    <div className="plugins-version-block">
                      <div className="plugins-theme-label">
                        Version
                        {!versionBusy && versions.length > 0 ? (
                          <span className="plugins-version-count">{versions.length} available</span>
                        ) : null}
                      </div>
                      <div className="plugins-version-row">
                        <VersionPicker
                          versions={versions}
                          value={pickedVersion}
                          loading={versionBusy}
                          disabled={busy}
                          placeholder={marketSelected.version || 'Latest'}
                          onChange={onPickVersion}
                        />
                      </div>
                      {pickedMeta && (
                        <div className="plugins-version-meta">
                          {pickedMeta.sinceUntil ? <span>Compatible: {pickedMeta.sinceUntil}</span> : null}
                          {typeof pickedMeta.downloads === 'number' ? (
                            <span>{pickedMeta.downloads.toLocaleString()}↓</span>
                          ) : null}
                          {formatBytes(pickedMeta.size) ? <span>{formatBytes(pickedMeta.size)}</span> : null}
                          {pickedMeta.publishedAt ? (
                            <span>{new Date(pickedMeta.publishedAt).toLocaleDateString()}</span>
                          ) : null}
                        </div>
                      )}
                      <p className="plugins-format-hint">
                        {marketSelected.kind === 'vscode'
                          ? 'Package format: .vsix · versions from Open VSX (+ VS Code Gallery)'
                          : marketSelected.kind === 'idea'
                            ? 'Package format: .zip / .jar · versions from JetBrains Marketplace'
                            : 'Package format: .zip'}
                      </p>
                    </div>

                    <div className="plugins-detail-actions">
                      <button
                        type="button"
                        className="plugins-btn primary"
                        disabled={busy}
                        onClick={() => void installMarketItem(marketSelected)}
                      >
                        {marketSelected.installed
                          ? `Install${pickedVersion ? ` v${pickedVersion}` : ''} (replace)`
                          : `Install${pickedVersion ? ` v${pickedVersion}` : ''}`}
                      </button>
                      <button
                        type="button"
                        className="plugins-btn"
                        disabled={busy}
                        onClick={() => void exportMarketItem(marketSelected)}
                      >
                        {exportLabel(marketSelected.kind)}
                      </button>
                      {marketSelected.url ? (
                        <button
                          type="button"
                          className="plugins-btn ghost"
                          onClick={() => void window.open(marketSelected.url, '_blank')}
                        >
                          Open page
                        </button>
                      ) : null}
                    </div>
                  </>
                ) : (
                  <div className="plugins-empty pad">Select a marketplace plugin</div>
                )}
              </section>
            </div>
          </div>
        )}
      </div>
    </div>
  )
}
