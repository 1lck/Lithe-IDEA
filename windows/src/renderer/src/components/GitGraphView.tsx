import type { GitLogEntry } from '@common/types'
import './GitGraphView.css'

interface Props {
  commits: GitLogEntry[]
  selected?: string | null
  onSelect?: (hash: string) => void
}

/** Lightweight lane sketch inspired by macOS GitGraphView. */
export function GitGraphView({ commits, selected, onSelect }: Props): JSX.Element {
  // Assign simple lanes by first-parent chain + branch refs
  const lanes = new Map<string, number>()
  let nextLane = 0
  for (const c of commits) {
    if (!lanes.has(c.hash)) {
      const parent = c.parents[0]
      if (parent && lanes.has(parent)) lanes.set(c.hash, lanes.get(parent)!)
      else {
        lanes.set(c.hash, nextLane)
        nextLane = Math.min(nextLane + 1, 6)
      }
    }
  }

  return (
    <div className="git-graph">
      {commits.map((c) => {
        const lane = lanes.get(c.hash) || 0
        const isHead = c.refs.some((r) => r.includes('HEAD'))
        return (
          <button
            key={c.hash}
            type="button"
            className={`gg-row ${selected === c.hash ? 'active' : ''}`}
            onClick={() => onSelect?.(c.hash)}
          >
            <span className="gg-rail" aria-hidden>
              <svg width="54" height="39" viewBox="0 0 54 39">
                <line
                  x1={12 + lane * 8}
                  y1="0"
                  x2={12 + lane * 8}
                  y2="39"
                  stroke="rgba(255,255,255,0.12)"
                  strokeWidth="1.5"
                />
                <circle
                  cx={12 + lane * 8}
                  cy="19.5"
                  r={isHead ? 4.5 : 3.5}
                  fill={isHead ? 'var(--lithe-accent)' : 'var(--lithe-success)'}
                />
              </svg>
            </span>
            <span className="gg-main">
              <span className="gg-labels">
                {c.refs.slice(0, 3).map((r) => (
                  <em
                    key={r}
                    className={`gg-chip ${
                      r.includes('HEAD') ? 'head' : r.includes('tag:') || r.includes('tag ') ? 'tag' : r.includes('origin') ? 'remote' : 'branch'
                    }`}
                  >
                    {r.replace(/^tag:\s*/, '')}
                  </em>
                ))}
              </span>
              <span className="gg-subject">{c.message}</span>
            </span>
            <span className="gg-author">{c.author}</span>
            <span className="gg-date">{new Date(c.date).toLocaleDateString()}</span>
          </button>
        )
      })}
      {commits.length === 0 && <div className="gg-empty">No commits loaded</div>}
    </div>
  )
}
