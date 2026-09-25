import { useMemo, useRef, type KeyboardEvent } from "react";
import { renderRunOutput } from "../utils/run-output-style";
import {
  ContextMenu,
  ContextMenuCheckboxItem,
  ContextMenuContent,
  ContextMenuTrigger,
} from "@/ui/context-menu";
import { cn } from "@/utils/cn";

export function RunOutputText({
  source,
  emptyLabel,
  title,
  wrapLines = true,
  wrapLabel,
  onToggleWrapLines,
}: {
  source: string;
  emptyLabel: string;
  title: string;
  /** Wrap output to the pane width; off keeps every line on one row with
   *  horizontal scrolling, matching the Git Console soft-wrap toggle. */
  wrapLines?: boolean;
  /** Label for the context-menu entry; the menu only appears when a toggle
   *  callback is provided, so store-less consumers stay unchanged. */
  wrapLabel?: string;
  onToggleWrapLines?: () => void;
}) {
  const preRef = useRef<HTMLPreElement>(null);
  const spans = useMemo(() => renderRunOutput(source), [source]);

  const outputClassName = wrapLines
    ? "whitespace-pre-wrap"
    : "w-max min-w-full whitespace-pre";

  const selectAll = () => {
    const node = preRef.current;
    const selection = window.getSelection();
    if (!node || !selection) return;
    const range = document.createRange();
    range.selectNodeContents(node);
    selection.removeAllRanges();
    selection.addRange(range);
  };

  const handleKeyDown = (event: KeyboardEvent<HTMLElement>) => {
    if (!(event.ctrlKey || event.metaKey) || event.key.toLowerCase() !== "a") return;
    event.preventDefault();
    event.stopPropagation();
    selectAll();
  };

  const content = (
    <>
      <div className="mb-1 font-medium text-subtle-foreground ui-text-sm">{title}</div>
      {source ? (
        <pre
          ref={preRef}
          className={cn(
            "cursor-text font-mono text-[12px] text-foreground select-text *:select-text",
            outputClassName,
          )}
        >
          {spans.map((span, index) => (
            <span key={index} className={span.className} style={span.style}>
              {span.text}
            </span>
          ))}
        </pre>
      ) : (
        <pre
          className={cn(
            "cursor-text font-mono text-[12px] text-foreground select-text",
            outputClassName,
          )}
        >
          {emptyLabel}
        </pre>
      )}
    </>
  );

  if (!onToggleWrapLines) {
    return (
      <div tabIndex={0} className="outline-none" onKeyDown={handleKeyDown}>
        {content}
      </div>
    );
  }

  return (
    <ContextMenu>
      <ContextMenuTrigger
        tabIndex={0}
        className="outline-none"
        onKeyDown={handleKeyDown}
        aria-label={title}
      >
        {content}
      </ContextMenuTrigger>
      <ContextMenuContent>
        <ContextMenuCheckboxItem
          checked={wrapLines}
          onCheckedChange={() => onToggleWrapLines()}
        >
          {wrapLabel}
        </ContextMenuCheckboxItem>
      </ContextMenuContent>
    </ContextMenu>
  );
}
