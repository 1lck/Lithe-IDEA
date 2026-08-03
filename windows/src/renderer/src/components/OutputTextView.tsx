import { useEffect, useMemo, useRef, useState } from 'react'
import './OutputTextView.css'

interface Props {
  output: string
  emptyMessage?: string
  onOpenLocation?: (path: string, line: number) => void
}

type Seg =
  | { kind: 'text'; text: string; tone?: string }
  | { kind: 'link'; text: string; path: string; line: number }

const ANSI_RE = /\x1b\[[0-9;]*m/g
const LOC_RE = /([A-Za-z]:\\[^\s:]+?|[./][^\s:]+?\.(?:java|kt|kts|ts|tsx|js|jsx|xml|py|go|rs))(?::(\d+))?/g

function stripAnsi(s: string): string {
  return s.replace(ANSI_RE, '')
}

function ansiTone(code: string): string | undefined {
  if (code.includes('31') || code.includes('91')) return 'err'
  if (code.includes('33') || code.includes('93')) return 'warn'
  if (code.includes('32') || code.includes('92')) return 'ok'
  if (code.includes('36') || code.includes('96')) return 'info'
  if (code.includes('1')) return 'bold'
  return undefined
}

function parseLine(raw: string): Seg[] {
  const segs: Seg[] = []
  let plain = ''
  let i = 0
  let tone: string | undefined
  while (i < raw.length) {
    if (raw[i] === '\x1b' && raw[i + 1] === '[') {
      if (plain) {
        segs.push({ kind: 'text', text: plain, tone })
        plain = ''
      }
      const end = raw.indexOf('m', i)
      if (end < 0) break
      const code = raw.slice(i + 2, end)
      tone = code === '0' || code === '' ? undefined : ansiTone(code) || tone
      i = end + 1
      continue
    }
    plain += raw[i]
    i++
  }
  if (plain) segs.push({ kind: 'text', text: plain, tone })

  // Linkify paths inside text segs
  const out: Seg[] = []
  for (const s of segs) {
    if (s.kind !== 'text') {
      out.push(s)
      continue
    }
    let last = 0
    const text = s.text
    LOC_RE.lastIndex = 0
    let m: RegExpExecArray | null
    while ((m = LOC_RE.exec(text))) {
      if (m.index > last) out.push({ kind: 'text', text: text.slice(last, m.index), tone: s.tone })
      out.push({
        kind: 'link',
        text: m[0],
        path: m[1],
        line: m[2] ? Number(m[2]) : 1
      })
      last = m.index + m[0].length
    }
    if (last < text.length) out.push({ kind: 'text', text: text.slice(last), tone: s.tone })
  }
  return out.length ? out : [{ kind: 'text', text: stripAnsi(raw) }]
}

/** macOS OutputTextView — ANSI + clickable locations, stick-to-bottom. */
export function OutputTextView({
  output,
  emptyMessage = 'No output yet',
  onOpenLocation
}: Props): JSX.Element {
  const ref = useRef<HTMLDivElement>(null)
  const [pinned, setPinned] = useState(true)
  const [showJump, setShowJump] = useState(false)

  const lines = useMemo(() => output.split(/\r?\n/), [output])

  useEffect(() => {
    const el = ref.current
    if (!el || !pinned) return
    el.scrollTop = el.scrollHeight
  }, [output, pinned])

  const onScroll = (): void => {
    const el = ref.current
    if (!el) return
    const atBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 40
    setPinned(atBottom)
    setShowJump(!atBottom)
  }

  const copy = async (): Promise<void> => {
    try {
      await navigator.clipboard.writeText(stripAnsi(output))
    } catch {
      /* ignore */
    }
  }

  const jump = (): void => {
    const el = ref.current
    if (!el) return
    el.scrollTop = el.scrollHeight
    setPinned(true)
    setShowJump(false)
  }

  return (
    <div className="otv">
      <div className="otv-tools">
        <button type="button" className="otv-capsule" onClick={() => void copy()} disabled={!output}>
          Copy
        </button>
      </div>
      <div className="otv-scroll" ref={ref} onScroll={onScroll}>
        {!output ? (
          <div className="otv-empty">{emptyMessage}</div>
        ) : (
          lines.map((line, idx) => (
            <div key={idx} className="otv-line">
              {parseLine(line).map((seg, j) =>
                seg.kind === 'link' ? (
                  <button
                    key={j}
                    type="button"
                    className="otv-link"
                    onClick={() => onOpenLocation?.(seg.path, seg.line)}
                    title={`Open ${seg.path}:${seg.line}`}
                  >
                    {seg.text}
                  </button>
                ) : (
                  <span key={j} className={seg.tone ? `otv-${seg.tone}` : undefined}>
                    {seg.text || '\u00a0'}
                  </span>
                )
              )}
            </div>
          ))
        )}
      </div>
      {showJump && (
        <button type="button" className="otv-jump" onClick={jump}>
          Jump to latest
        </button>
      )}
    </div>
  )
}
