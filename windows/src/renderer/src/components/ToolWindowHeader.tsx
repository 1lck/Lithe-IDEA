import type { ReactNode } from 'react'
import './ToolWindowHeader.css'

interface Props {
  title: string
  subtitle?: string
  icon?: ReactNode
  onMinimize?: () => void
  children?: ReactNode
}

/** macOS LitheToolWindowHeader — 30px graphite chrome for tool windows. */
export function ToolWindowHeader({ title, subtitle, icon, onMinimize, children }: Props): JSX.Element {
  return (
    <header className="twh">
      <div className="twh-lead">
        {icon ? <span className="twh-icon">{icon}</span> : null}
        <strong>{title}</strong>
        {subtitle ? <span className="twh-sub">{subtitle}</span> : null}
      </div>
      <div className="twh-actions">
        {children}
        {onMinimize ? (
          <button type="button" className="twh-btn" title={`Hide ${title}`} onClick={onMinimize} aria-label="Minimize">
            <svg viewBox="0 0 12 12" width="12" height="12" aria-hidden>
              <path d="M2.5 6h7" fill="none" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" />
            </svg>
          </button>
        ) : null}
      </div>
    </header>
  )
}
