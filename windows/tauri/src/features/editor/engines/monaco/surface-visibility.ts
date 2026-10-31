/**
 * Editor tabs keep their Monaco surfaces mounted while hidden, so Monaco still
 * treats their models as attached and asks providers to refresh them whenever
 * a language server event fires. Surfaces report their visibility here so
 * providers can skip models that only hidden surfaces show and refresh them
 * once one of those surfaces is shown again.
 *
 * Models no surface registered (diff views, notebooks) are never treated as
 * hidden.
 */
interface SurfaceCounts {
  visible: number;
  hidden: number;
}

const surfaces = new Map<string, SurfaceCounts>();
const shownListeners = new Set<(uri: string) => void>();

function counts(uri: string): SurfaceCounts {
  let entry = surfaces.get(uri);
  if (!entry) {
    entry = { visible: 0, hidden: 0 };
    surfaces.set(uri, entry);
  }
  return entry;
}

export interface MonacoSurfaceRegistration {
  setVisible(visible: boolean): void;
  dispose(): void;
}

export function registerMonacoSurface(uri: string, visible: boolean): MonacoSurfaceRegistration {
  let current = visible;
  let disposed = false;
  const entry = counts(uri);
  if (current) entry.visible++;
  else entry.hidden++;
  if (current && entry.visible === 1) notifyShown(uri);

  return {
    setVisible(next) {
      if (disposed || next === current) return;
      const target = counts(uri);
      if (next) {
        target.hidden--;
        target.visible++;
      } else {
        target.visible--;
        target.hidden++;
      }
      current = next;
      if (next && target.visible === 1) notifyShown(uri);
    },
    dispose() {
      if (disposed) return;
      disposed = true;
      const target = counts(uri);
      if (current) target.visible--;
      else target.hidden--;
      if (target.visible <= 0 && target.hidden <= 0) surfaces.delete(uri);
    },
  };
}

/** Whether every registered surface showing this model is currently hidden. */
export function isMonacoModelOnlyHidden(uri: string): boolean {
  const entry = surfaces.get(uri);
  return entry !== undefined && entry.visible <= 0 && entry.hidden > 0;
}

export function onMonacoModelShown(listener: (uri: string) => void): () => void {
  shownListeners.add(listener);
  return () => shownListeners.delete(listener);
}

function notifyShown(uri: string): void {
  for (const listener of shownListeners) listener(uri);
}

/**
 * Remembers models a provider skipped while hidden and asks for one refresh
 * when any of them is shown again.
 */
export function createHiddenModelRefresh(refresh: () => void) {
  const skipped = new Set<string>();
  const stop = onMonacoModelShown((uri) => {
    if (skipped.delete(uri)) refresh();
  });
  return {
    /** Returns true when the provider must not request data for this model now. */
    skipIfHidden(uri: string): boolean {
      if (!isMonacoModelOnlyHidden(uri)) return false;
      skipped.add(uri);
      return true;
    },
    dispose: stop,
  };
}

export function resetMonacoSurfacesForTests(): void {
  surfaces.clear();
  shownListeners.clear();
}
