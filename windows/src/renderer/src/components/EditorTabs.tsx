import './EditorTabs.css'

interface Tab {
  id: string
  name: string
  content: string
  savedContent: string
}

interface Props {
  tabs: Tab[]
  activeId: string | null
  onSelect: (id: string) => void
  onClose: (id: string) => void
}

export function EditorTabs({ tabs, activeId, onSelect, onClose }: Props): JSX.Element {
  if (tabs.length === 0) return <div className="tabs-bar empty" />
  return (
    <div className="tabs-bar">
      {tabs.map((tab) => {
        const isDirty = tab.content !== tab.savedContent
        const isActive = tab.id === activeId
        return (
          <div
            key={tab.id}
            className={`tab ${isActive ? 'active' : ''}`}
            onClick={() => onSelect(tab.id)}
          >
            <span className="tab-name">
              {isDirty && <span className="tab-dirty" aria-label="unsaved" />}
              {tab.name}
            </span>
            <button
              className="tab-close"
              onClick={(e) => { e.stopPropagation(); onClose(tab.id) }}
            >
              &times;
            </button>
          </div>
        )
      })}
    </div>
  )
}
