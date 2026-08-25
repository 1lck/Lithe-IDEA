import { useEffect, useMemo, useRef, useState } from "react";
import type { Position } from "@/features/editor/types/editor.types";
import { useEditorStateStore } from "@/features/editor/stores/state.store";
import { resolveEditorViewCursorPosition } from "@/features/editor/utils/editor-view-cursor-position";
import { useTranslation } from "@/i18n/locale-provider";
import { cn } from "@/utils/cn";

const statusChipClass =
  "font-sans inline-flex h-5 items-center self-center rounded-full border-0 px-1.5 ui-text-sm leading-none text-subtle-foreground transition-colors hover:bg-accent hover:text-foreground";

export function CursorPositionChip({ editorViewKey }: { editorViewKey?: string | null }) {
  const { t } = useTranslation();
  const activeEditorViewKey = useEditorStateStore.use.activeEditorViewKey();
  const cursorPosition = useEditorStateStore.use.cursorPosition();
  const [isEditing, setIsEditing] = useState(false);
  const [draftPosition, setDraftPosition] = useState("");
  const inputRef = useRef<HTMLInputElement>(null);
  const displayedCursorPosition = useMemo<Position>(() => {
    const cachedCursor = editorViewKey
      ? useEditorStateStore.getState().actions.getCachedPosition(editorViewKey)
      : undefined;
    return resolveEditorViewCursorPosition(
      editorViewKey,
      activeEditorViewKey,
      cursorPosition,
      cachedCursor,
    );
  }, [activeEditorViewKey, cursorPosition, editorViewKey]);
  const displayPosition = `${displayedCursorPosition.line + 1}:${displayedCursorPosition.column + 1}`;

  useEffect(() => {
    if (!isEditing) return;
    setDraftPosition(displayPosition);
    const frameId = requestAnimationFrame(() => {
      inputRef.current?.focus();
      inputRef.current?.select();
    });
    return () => cancelAnimationFrame(frameId);
  }, [displayPosition, isEditing]);

  const submitPosition = () => {
    const match = draftPosition.trim().match(/^(\d+)(?::(\d+))?$/);
    if (!match) {
      setIsEditing(false);
      return;
    }

    const line = Number(match[1]);
    const column = match[2] ? Number(match[2]) : 1;

    if (!Number.isFinite(line) || !Number.isFinite(column) || line < 1 || column < 1) {
      setIsEditing(false);
      return;
    }

    window.dispatchEvent(new CustomEvent("menu-go-to-line", { detail: { line, column } }));
    setIsEditing(false);
  };

  if (isEditing) {
    return (
      <input
        ref={inputRef}
        aria-label={t("editor.goToLineColumn")}
        value={draftPosition}
        onChange={(event) => setDraftPosition(event.target.value)}
        onBlur={submitPosition}
        onKeyDown={(event) => {
          if (event.key === "Enter") {
            event.preventDefault();
            submitPosition();
          } else if (event.key === "Escape") {
            event.preventDefault();
            setIsEditing(false);
          }
        }}
        className={cn(
          statusChipClass,
          "w-14 bg-accent text-foreground outline-none focus-visible:ring-2 focus-visible:ring-primary/20",
        )}
      />
    );
  }

  return (
    <button
      type="button"
      className={statusChipClass}
      onClick={() => setIsEditing(true)}
      aria-label={t("editor.goToLineColumn")}
    >
      {displayPosition}
    </button>
  );
}
