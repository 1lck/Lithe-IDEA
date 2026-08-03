import { useEffect, useMemo, useRef, useState } from 'react'
import type { MarketplaceVersion } from '@common/types'

interface Props {
  versions: MarketplaceVersion[]
  value: string
  disabled?: boolean
  loading?: boolean
  placeholder?: string
  onChange: (version: string, item: MarketplaceVersion | undefined) => void
}

function formatDate(iso?: string): string {
  if (!iso) return ''
  try {
    return new Date(iso).toLocaleDateString()
  } catch {
    return ''
  }
}

/** Lithe-styled searchable version picker — no native `<select>`. */
export function VersionPicker({
  versions,
  value,
  disabled,
  loading,
  placeholder = 'Select version',
  onChange
}: Props): JSX.Element {
  const [open, setOpen] = useState(false)
  const [filter, setFilter] = useState('')
  const [highlight, setHighlight] = useState(0)
  const rootRef = useRef<HTMLDivElement>(null)
  const searchRef = useRef<HTMLInputElement>(null)
  const listRef = useRef<HTMLDivElement>(null)

  const filtered = useMemo(() => {
    const q = filter.trim().toLowerCase()
    if (!q) return versions
    return versions.filter(
      (v) =>
        v.version.toLowerCase().includes(q) ||
        (v.channel || '').toLowerCase().includes(q) ||
        (v.sinceUntil || '').toLowerCase().includes(q)
    )
  }, [versions, filter])

  const selected = versions.find((v) => v.version === value)

  useEffect(() => {
    if (!open) return
    const onDoc = (e: MouseEvent): void => {
      if (!rootRef.current?.contains(e.target as Node)) setOpen(false)
    }
    const onKey = (e: KeyboardEvent): void => {
      if (e.key === 'Escape') setOpen(false)
    }
    document.addEventListener('mousedown', onDoc)
    document.addEventListener('keydown', onKey)
    return () => {
      document.removeEventListener('mousedown', onDoc)
      document.removeEventListener('keydown', onKey)
    }
  }, [open])

  useEffect(() => {
    if (open) {
      setFilter('')
      setHighlight(Math.max(0, filtered.findIndex((v) => v.version === value)))
      requestAnimationFrame(() => searchRef.current?.focus())
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open])

  useEffect(() => {
    setHighlight(0)
  }, [filter])

  useEffect(() => {
    if (!open || !listRef.current) return
    const el = listRef.current.querySelector<HTMLElement>(`[data-idx="${highlight}"]`)
    el?.scrollIntoView({ block: 'nearest' })
  }, [highlight, open])

  const pick = (item: MarketplaceVersion): void => {
    onChange(item.version, item)
    setOpen(false)
  }

  const onTriggerKey = (e: React.KeyboardEvent): void => {
    if (disabled || loading) return
    if (e.key === 'Enter' || e.key === ' ' || e.key === 'ArrowDown') {
      e.preventDefault()
      setOpen(true)
    }
  }

  const onListKey = (e: React.KeyboardEvent): void => {
    if (e.key === 'ArrowDown') {
      e.preventDefault()
      setHighlight((h) => Math.min(filtered.length - 1, h + 1))
    } else if (e.key === 'ArrowUp') {
      e.preventDefault()
      setHighlight((h) => Math.max(0, h - 1))
    } else if (e.key === 'Enter') {
      e.preventDefault()
      const item = filtered[highlight]
      if (item) pick(item)
    }
  }

  const label = loading
    ? 'Loading versions…'
    : selected
      ? selected.version
      : value || placeholder

  return (
    <div className={`vpick ${open ? 'is-open' : ''} ${disabled ? 'is-disabled' : ''}`} ref={rootRef}>
      <button
        type="button"
        className="vpick-trigger"
        disabled={disabled || loading}
        aria-haspopup="listbox"
        aria-expanded={open}
        onClick={() => setOpen((o) => !o)}
        onKeyDown={onTriggerKey}
      >
        <span className="vpick-value">
          <strong>{label}</strong>
          {selected?.sinceUntil ? <em>{selected.sinceUntil}</em> : null}
        </span>
        <span className="vpick-meta">
          {!loading && versions.length > 0 ? `${versions.length}` : ''}
          <svg className="vpick-chevron" width="12" height="12" viewBox="0 0 12 12" aria-hidden>
            <path d="M2.5 4.5L6 8l3.5-3.5" fill="none" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" />
          </svg>
        </span>
      </button>

      {open && (
        <div className="vpick-panel" role="listbox" onKeyDown={onListKey}>
          <div className="vpick-search">
            <input
              ref={searchRef}
              value={filter}
              onChange={(e) => setFilter(e.target.value)}
              placeholder="Filter versions…"
              spellCheck={false}
            />
          </div>
          <div className="vpick-list" ref={listRef}>
            {filtered.length === 0 && <div className="vpick-empty">No matching versions</div>}
            {filtered.map((v, idx) => {
              const active = v.version === value
              const hi = idx === highlight
              return (
                <button
                  key={`${v.version}-${v.updateId || idx}`}
                  type="button"
                  role="option"
                  aria-selected={active}
                  data-idx={idx}
                  className={`vpick-option ${active ? 'is-active' : ''} ${hi ? 'is-hi' : ''}`}
                  onMouseEnter={() => setHighlight(idx)}
                  onClick={() => pick(v)}
                >
                  <span className="vpick-option-main">
                    <span className="vpick-option-ver">{v.version}</span>
                    {v.channel && v.channel !== 'stable' ? (
                      <span className="vpick-chip">{v.channel}</span>
                    ) : null}
                  </span>
                  <span className="vpick-option-side">
                    {v.sinceUntil ? <span>{v.sinceUntil}</span> : null}
                    {formatDate(v.publishedAt) ? <span>{formatDate(v.publishedAt)}</span> : null}
                    {typeof v.downloads === 'number' ? (
                      <span>{v.downloads.toLocaleString()}↓</span>
                    ) : null}
                  </span>
                </button>
              )
            })}
          </div>
          <div className="vpick-foot">
            {filtered.length === versions.length
              ? `${versions.length} versions`
              : `${filtered.length} / ${versions.length} versions`}
          </div>
        </div>
      )}
    </div>
  )
}
