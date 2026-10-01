export interface DocumentResizeSessionOptions {
  startX: number;
  startWidth: number;
  clampWidth: (value: number) => number;
  applyWidth: (width: number) => void;
  commitWidth: (width: number) => void;
  onActiveChange?: (active: boolean) => void;
  /**
   * `1` (default) grows the width as the pointer moves right, for a handle on the right edge of
   * the resized element. `-1` grows it as the pointer moves left, for a right-anchored element
   * whose handle sits on its left edge.
   */
  direction?: 1 | -1;
  /** Cursor forced on the body while dragging so it does not flicker over other elements. */
  cursor?: string;
  target?: Pick<Document, "addEventListener" | "removeEventListener">;
  view?: Pick<Window, "addEventListener" | "removeEventListener">;
  bodyStyle?: { cursor: string; userSelect: string };
  scheduleFrame?: (callback: FrameRequestCallback) => number;
  cancelFrame?: (handle: number) => void;
}

export interface DocumentResizeSession {
  /** Removes listeners, resets body styles, cancels RAF, and optionally commits. */
  dispose: (options?: { commit?: boolean }) => void;
}

/**
 * Owns pointer-drag listeners for a horizontal resize.
 * Cleanup is idempotent and safe for mouseup, blur, pointercancel, and unmount.
 *
 * `applyWidth` is coalesced to one call per animation frame and should only touch the DOM;
 * `commitWidth` runs once when the drag ends and is the place to persist state.
 */
export function startDocumentResizeSession(
  options: DocumentResizeSessionOptions,
): DocumentResizeSession {
  const target = options.target ?? document;
  const view = options.view ?? window;
  const bodyStyle = options.bodyStyle ?? document.body.style;
  const scheduleFrame = options.scheduleFrame ?? requestAnimationFrame.bind(window);
  const cancelFrame = options.cancelFrame ?? cancelAnimationFrame.bind(window);
  const direction = options.direction ?? 1;

  let currentWidth = options.startWidth;
  let rafId: number | null = null;
  let disposed = false;

  const cleanup = (commit: boolean) => {
    if (disposed) {
      return;
    }
    disposed = true;

    if (rafId !== null) {
      cancelFrame(rafId);
      rafId = null;
    }

    target.removeEventListener("pointermove", handlePointerMove);
    target.removeEventListener("pointerup", handlePointerEnd);
    target.removeEventListener("pointercancel", handlePointerEnd);
    view.removeEventListener("blur", handleBlur);

    bodyStyle.cursor = "";
    bodyStyle.userSelect = "";
    options.onActiveChange?.(false);

    if (commit) {
      options.commitWidth(currentWidth);
    }
  };

  const handlePointerMove = (event: Event) => {
    const pointerEvent = event as PointerEvent;
    currentWidth = options.clampWidth(
      options.startWidth + direction * (pointerEvent.clientX - options.startX),
    );
    if (rafId !== null) {
      cancelFrame(rafId);
    }
    rafId = scheduleFrame(() => {
      options.applyWidth(currentWidth);
    });
  };

  const handlePointerEnd = () => {
    cleanup(true);
  };

  const handleBlur = () => {
    cleanup(true);
  };

  options.onActiveChange?.(true);
  bodyStyle.cursor = options.cursor ?? "col-resize";
  bodyStyle.userSelect = "none";

  target.addEventListener("pointermove", handlePointerMove);
  target.addEventListener("pointerup", handlePointerEnd);
  target.addEventListener("pointercancel", handlePointerEnd);
  view.addEventListener("blur", handleBlur);

  return {
    dispose: ({ commit = true } = {}) => {
      cleanup(commit);
    },
  };
}
