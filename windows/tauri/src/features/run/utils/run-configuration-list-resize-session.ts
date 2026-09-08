import {
  clampRunConfigurationListWidth,
} from "./run-configuration-list-layout";

/** Matches the file-navigator sidebar keyboard resize step. */
export const RUN_CONFIGURATION_LIST_RESIZE_STEP = 16;

export function nextRunConfigurationListWidthForKey(
  currentWidth: number,
  key: string,
  containerWidth: number,
): number | null {
  if (key !== "ArrowLeft" && key !== "ArrowRight") {
    return null;
  }

  const delta =
    key === "ArrowRight"
      ? RUN_CONFIGURATION_LIST_RESIZE_STEP
      : -RUN_CONFIGURATION_LIST_RESIZE_STEP;
  return clampRunConfigurationListWidth(currentWidth + delta, containerWidth);
}

export interface DocumentResizeSessionOptions {
  startX: number;
  startWidth: number;
  clampWidth: (value: number) => number;
  applyWidth: (width: number) => void;
  commitWidth: (width: number) => void;
  onActiveChange?: (active: boolean) => void;
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
 * Owns pointer-drag listeners for a horizontal list resize.
 * Cleanup is idempotent and safe for mouseup, blur, pointercancel, and unmount.
 */
export function startDocumentResizeSession(
  options: DocumentResizeSessionOptions,
): DocumentResizeSession {
  const target = options.target ?? document;
  const view = options.view ?? window;
  const bodyStyle = options.bodyStyle ?? document.body.style;
  const scheduleFrame = options.scheduleFrame ?? requestAnimationFrame.bind(window);
  const cancelFrame = options.cancelFrame ?? cancelAnimationFrame.bind(window);

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
    currentWidth = options.clampWidth(options.startWidth + (pointerEvent.clientX - options.startX));
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
  bodyStyle.cursor = "col-resize";
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
