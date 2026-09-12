import { EDITOR_CONSTANTS } from "@/features/editor/config/constants";

export interface CachedScrollPosition {
  scrollTop: number;
  scrollLeft: number;
}

export interface NativeEditorViewStateHandle {
  save: () => unknown;
  restore: (state: unknown) => void;
}

interface ViewStateRestoreEditor {
  layout: () => void;
  setScrollPosition: (position: CachedScrollPosition) => void;
}

interface ScheduleCachedViewStateRestoreOptions {
  editor: ViewStateRestoreEditor;
  cachedScroll?: CachedScrollPosition;
  restoreEditor?: () => void;
  isEditorCurrent: () => boolean;
  isNavigationRevisionCurrent: () => boolean;
  focus: () => void;
  onRestoreComplete: () => void;
}

const nativeViewStateCache = new Map<string, unknown>();

function trimNativeViewStateCache(viewKey: string): void {
  if (
    nativeViewStateCache.size < EDITOR_CONSTANTS.MAX_POSITION_CACHE_SIZE ||
    nativeViewStateCache.has(viewKey)
  ) {
    return;
  }

  const firstKey = nativeViewStateCache.keys().next().value;
  if (firstKey) nativeViewStateCache.delete(firstKey);
}

/**
 * Keep the last known non-zero viewport when a hidden/layout pass reports 0.
 * A genuine scroll-to-top is already written to the cache while the surface is
 * active, so a later 0+stale-cache pair is a reset rather than user intent.
 */
export function resolveScrollToPersist(
  live: CachedScrollPosition,
  cached?: CachedScrollPosition | null,
): CachedScrollPosition {
  if (
    live.scrollTop === 0 &&
    live.scrollLeft === 0 &&
    cached &&
    (cached.scrollTop !== 0 || cached.scrollLeft !== 0)
  ) {
    return { scrollTop: cached.scrollTop, scrollLeft: cached.scrollLeft };
  }

  return live;
}

export function persistNativeEditorViewState(
  viewKey: string,
  handle: NativeEditorViewStateHandle,
): void {
  if (!viewKey) return;
  const state = handle.save();
  if (state == null) return;
  trimNativeViewStateCache(viewKey);
  nativeViewStateCache.set(viewKey, state);
}

export function restoreNativeEditorViewState(
  viewKey: string,
  handle: NativeEditorViewStateHandle,
): boolean {
  if (!viewKey) return false;
  const state = nativeViewStateCache.get(viewKey);
  if (state == null) return false;
  handle.restore(state);
  return true;
}

export function persistEditorViewportState(options: {
  viewKey: string;
  liveScroll: CachedScrollPosition;
  cached?: CachedScrollPosition | null;
  native?: NativeEditorViewStateHandle;
}): CachedScrollPosition {
  const preservedScroll = resolveScrollToPersist(options.liveScroll, options.cached);
  const liveLooksReset =
    options.liveScroll.scrollTop === 0 &&
    options.liveScroll.scrollLeft === 0 &&
    (preservedScroll.scrollTop !== 0 || preservedScroll.scrollLeft !== 0);
  if (options.native && !liveLooksReset) {
    persistNativeEditorViewState(options.viewKey, options.native);
  }
  return preservedScroll;
}

export function clearNativeEditorViewState(viewKey?: string): void {
  if (viewKey) {
    nativeViewStateCache.delete(viewKey);
    return;
  }
  nativeViewStateCache.clear();
}

/**
 * Tracks overlapping view-state restores so an older create/activation RAF
 * cannot clear the restoring flag while a newer restore is still in flight.
 */
export function createViewStateRestoreGate(): {
  isRestoring: () => boolean;
  begin: () => () => void;
} {
  let generation = 0;
  let restoring = false;

  return {
    isRestoring: () => restoring,
    begin: () => {
      const current = ++generation;
      restoring = true;
      return () => {
        if (generation === current) restoring = false;
      };
    },
  };
}

/**
 * Replays the existing post-layout view-state restoration frames while ensuring
 * that a newer owner-directed history navigation keeps its scroll position.
 */
export function scheduleCachedViewStateRestore(
  options: ScheduleCachedViewStateRestoreOptions,
): () => void {
  const restoreCachedScroll = () => {
    if (!options.isNavigationRevisionCurrent()) return;
    if (options.restoreEditor) {
      options.restoreEditor();
      return;
    }
    if (!options.cachedScroll) return;
    options.editor.setScrollPosition(options.cachedScroll);
  };

  let confirmationFrame: number | null = null;
  const focusFrame = requestAnimationFrame(() => {
    if (!options.isEditorCurrent()) {
      options.onRestoreComplete();
      return;
    }

    options.editor.layout();
    restoreCachedScroll();
    options.focus();
    confirmationFrame = requestAnimationFrame(() => {
      if (options.isEditorCurrent()) {
        restoreCachedScroll();
        options.focus();
      }
      options.onRestoreComplete();
    });
  });

  return () => {
    cancelAnimationFrame(focusFrame);
    if (confirmationFrame !== null) cancelAnimationFrame(confirmationFrame);
  };
}
