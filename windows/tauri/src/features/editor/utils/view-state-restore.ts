export interface CachedScrollPosition {
  scrollTop: number;
  scrollLeft: number;
}

interface ViewStateRestoreEditor {
  layout: () => void;
  setScrollPosition: (position: CachedScrollPosition) => void;
}

interface ScheduleCachedViewStateRestoreOptions {
  editor: ViewStateRestoreEditor;
  cachedScroll?: CachedScrollPosition;
  isEditorCurrent: () => boolean;
  isNavigationRevisionCurrent: () => boolean;
  focus: () => void;
  onRestoreComplete: () => void;
}

/**
 * Replays the existing post-layout view-state restoration frames while ensuring
 * that a newer owner-directed history navigation keeps its scroll position.
 */
export function scheduleCachedViewStateRestore(
  options: ScheduleCachedViewStateRestoreOptions,
): () => void {
  const restoreCachedScroll = () => {
    if (!options.cachedScroll || !options.isNavigationRevisionCurrent()) return;
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
