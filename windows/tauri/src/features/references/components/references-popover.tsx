import {
  FileCodeIcon as FileCode,
  ArrowsOutIcon as Maximize2,
  XIcon as X,
} from "@/ui/icons";
import { useCallback, useEffect, useRef, useState } from "react";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { useTranslation } from "@/i18n/locale-provider";
import { useReferencesStore } from "../stores/references.store";
import { useUIState } from "@/features/window/stores/ui-state.store";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { cn } from "@/utils/cn";
import type { Reference } from "../types/reference.types";

/** Derives the cursor position from Monaco's `.cursor` DOM element. */
function getCursorScreenRect(): DOMRect | null {
  const cursor = document.querySelector<HTMLElement>(".monaco-editor .cursor");
  return cursor ? cursor.getBoundingClientRect() : null;
}

const getFileName = (filePath: string) => {
  const parts = filePath.split(/[\\/]/);
  return parts[parts.length - 1] || filePath;
};

interface Position {
  top: number;
  left: number;
  /** When true the popover opens upward from the cursor. */
  flipUp: boolean;
}

const POPOVER_MAX_HEIGHT = 320;
const POPOVER_ESTIMATED_WIDTH = 520;
const CURSOR_GAP = 4;

function computePosition(cursorRect: DOMRect): Position {
  const vw = window.innerWidth;
  const vh = window.innerHeight;

  const spaceBelow = vh - cursorRect.bottom - CURSOR_GAP;
  const flipUp = spaceBelow < POPOVER_MAX_HEIGHT && cursorRect.top > POPOVER_MAX_HEIGHT;

  const rawLeft = cursorRect.left;
  const left = Math.min(Math.max(rawLeft, 8), vw - POPOVER_ESTIMATED_WIDTH - 8);

  if (flipUp) {
    return { top: cursorRect.top - CURSOR_GAP, left, flipUp: true };
  }
  return { top: cursorRect.bottom + CURSOR_GAP, left, flipUp: false };
}

export function ReferencesPopover() {
  const { t } = useTranslation();
  const isVisible = useUIState((state) => state.isReferencesPopoverVisible);
  const references = useReferencesStore.use.references();
  const query = useReferencesStore.use.query();
  const isLoading = useReferencesStore.use.isLoading();
  const handleFileSelect = useFileSystemStore.use.handleFileSelect?.();
  const [position, setPosition] = useState<Position | null>(null);
  const [activeIndex, setActiveIndex] = useState(0);
  const listRef = useRef<HTMLDivElement>(null);
  const containerRef = useRef<HTMLDivElement>(null);

  const close = useCallback(() => {
    useUIState.getState().setIsReferencesPopoverVisible(false);
  }, []);

  const openInPanel = useCallback(() => {
    close();
    useBufferStore.getState().actions.openReferencesBuffer();
  }, [close]);

  // Derive position from cursor when popover becomes visible.
  useEffect(() => {
    if (!isVisible) return;
    setActiveIndex(0);
    const rect = getCursorScreenRect();
    setPosition(rect ? computePosition(rect) : null);
  }, [isVisible]);

  // Scroll active item into view.
  useEffect(() => {
    const el = listRef.current?.children[activeIndex] as HTMLElement | undefined;
    el?.scrollIntoView({ block: "nearest" });
  }, [activeIndex]);

  const navigate = useCallback(
    (ref: Reference) => {
      void handleFileSelect?.(ref.filePath, false, ref.line + 1, ref.column + 1, undefined, false);
      close();
    },
    [handleFileSelect, close],
  );

  // Click-outside handler.
  useEffect(() => {
    if (!isVisible) return;
    const handler = (e: MouseEvent) => {
      if (containerRef.current && !containerRef.current.contains(e.target as Node)) {
        close();
      }
    };
    document.addEventListener("mousedown", handler);
    return () => document.removeEventListener("mousedown", handler);
  }, [isVisible, close]);

  // Keyboard navigation.
  useEffect(() => {
    if (!isVisible) return;
    const handler = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        e.stopPropagation();
        close();
        return;
      }
      if (references.length === 0) return;
      if (e.key === "ArrowDown") {
        e.preventDefault();
        setActiveIndex((i) => Math.min(i + 1, references.length - 1));
      } else if (e.key === "ArrowUp") {
        e.preventDefault();
        setActiveIndex((i) => Math.max(i - 1, 0));
      } else if (e.key === "Enter") {
        e.preventDefault();
        navigate(references[activeIndex]);
      }
    };
    document.addEventListener("keydown", handler, { capture: true });
    return () => document.removeEventListener("keydown", handler, { capture: true });
  }, [isVisible, references, activeIndex, navigate, close]);

  if (!isVisible) return null;
  if (!position) return null;

  const positionStyle: React.CSSProperties = position.flipUp
    ? { bottom: `calc(100vh - ${position.top}px)`, left: position.left }
    : { top: position.top, left: position.left };

  return (
    <div
      ref={containerRef}
      style={{ ...positionStyle, position: "fixed", zIndex: 200 }}
      className={cn(
        "w-[520px] overflow-hidden rounded-lg border border-border bg-popover shadow-lg",
        "flex flex-col",
      )}
    >
      {/* Header */}
      <div className="flex items-center justify-between border-b border-border px-3 py-2">
        <div className="flex items-center gap-2 min-w-0">
          <span className="font-medium text-foreground ui-text-sm truncate">
            {query?.symbol ?? t("references.title")}
          </span>
          <span className="shrink-0 rounded-full bg-accent px-1.5 py-0.5 ui-text-xs text-subtle-foreground">
            {isLoading ? "..." : references.length}
          </span>
        </div>
        <div className="flex items-center gap-0.5 shrink-0 ml-2">
          <button
            type="button"
            onClick={openInPanel}
            className="flex h-5 w-5 items-center justify-center rounded text-subtle-foreground transition-colors hover:bg-accent hover:text-foreground"
            title={t("references.fullscreen")}
          >
            <Maximize2 size={12} />
          </button>
          <button
            type="button"
            onClick={close}
            className="flex h-5 w-5 items-center justify-center rounded text-subtle-foreground transition-colors hover:bg-accent hover:text-foreground"
            title={t("references.clearReferences")}
          >
            <X size={12} />
          </button>
        </div>
      </div>

      {/* Body */}
      <div
        ref={listRef}
        className="overflow-y-auto"
        style={{ maxHeight: POPOVER_MAX_HEIGHT - 36 }}
      >
        {isLoading ? (
          <div className="px-3 py-2 text-subtle-foreground ui-text-sm">
            {t("references.findingReferences")}
          </div>
        ) : references.length === 0 ? (
          <div className="px-3 py-2 text-subtle-foreground ui-text-sm">
            {t("references.noReferencesFound")}
          </div>
        ) : (
          references.map((ref, index) => (
            <button
              type="button"
              key={`${ref.filePath}:${ref.line}:${ref.column}`}
              onClick={() => navigate(ref)}
              onMouseEnter={() => setActiveIndex(index)}
              className={cn(
                "flex w-full items-center gap-0 px-2 py-0.5 text-left transition-colors",
                index === activeIndex ? "bg-accent" : "hover:bg-accent/50",
              )}
            >
              {/* File icon */}
              <FileCode
                size={12}
                className="mr-1.5 shrink-0 text-primary"
                weight="duotone"
              />
              {/* Filename — fixed width, truncate long names */}
              <span
                className="shrink-0 truncate font-mono ui-text-xs text-foreground"
                style={{ width: "11rem" }}
                title={ref.filePath}
              >
                {getFileName(ref.filePath)}
              </span>
              {/* Line number — right-aligned in fixed column */}
              <span
                className="shrink-0 tabular-nums font-mono ui-text-xs text-subtle-foreground text-right"
                style={{ width: "3rem" }}
              >
                {ref.line + 1}
              </span>
              {/* Code content — takes remaining space */}
              <span className="ml-3 min-w-0 truncate ui-text-sm text-subtle-foreground">
                {ref.lineContent.trim()}
              </span>
            </button>
          ))
        )}
      </div>
    </div>
  );
}
