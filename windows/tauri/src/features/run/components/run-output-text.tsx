import { useMemo, useRef, type KeyboardEvent } from "react";
import { renderRunOutput } from "../utils/run-output-style";

export function RunOutputText({
  source,
  emptyLabel,
  title,
}: {
  source: string;
  emptyLabel: string;
  title: string;
}) {
  const preRef = useRef<HTMLPreElement>(null);
  const spans = useMemo(() => renderRunOutput(source), [source]);

  const selectAll = () => {
    const node = preRef.current;
    const selection = window.getSelection();
    if (!node || !selection) return;
    const range = document.createRange();
    range.selectNodeContents(node);
    selection.removeAllRanges();
    selection.addRange(range);
  };

  const handleKeyDown = (event: KeyboardEvent<HTMLDivElement>) => {
    if (!(event.ctrlKey || event.metaKey) || event.key.toLowerCase() !== "a") return;
    event.preventDefault();
    event.stopPropagation();
    selectAll();
  };

  return (
    <div tabIndex={0} className="outline-none" onKeyDown={handleKeyDown}>
      <div className="mb-1 font-medium text-subtle-foreground ui-text-sm">{title}</div>
      {source ? (
        <pre
          ref={preRef}
          className="cursor-text whitespace-pre-wrap font-mono text-[12px] text-foreground select-text *:select-text"
        >
          {spans.map((span, index) => (
            <span key={index} className={span.className} style={span.style}>
              {span.text}
            </span>
          ))}
        </pre>
      ) : (
        <pre className="cursor-text whitespace-pre-wrap font-mono text-[12px] text-foreground select-text">
          {emptyLabel}
        </pre>
      )}
    </div>
  );
}
