import { useLayoutEffect, useRef, type RefObject } from "react";

type OpenFileAction = () => unknown;
type ResolveFileTarget = (focusedElement: Element) => OpenFileAction | undefined;

// Views retain selection and location ownership; the command only follows DOM focus.
const fileOpenTargets = new WeakMap<Element, ResolveFileTarget>();

export function useFileOpenTarget(
  regionRef: RefObject<Element | null>,
  resolveTarget: ResolveFileTarget,
): void {
  const resolveRef = useRef(resolveTarget);
  resolveRef.current = resolveTarget;

  useLayoutEffect(() => {
    const region = regionRef.current;
    if (!region) return;
    fileOpenTargets.set(region, (element) => resolveRef.current(element));
    return () => {
      fileOpenTargets.delete(region);
    };
  }, [regionRef]);
}

export function resolveFocusedFileOpenTarget(): OpenFileAction | undefined {
  const focusedElement = document.activeElement;
  if (!focusedElement) return;
  for (let region: Element | null = focusedElement; region; region = region.parentElement) {
    const resolver = fileOpenTargets.get(region);
    if (resolver) return resolver(focusedElement);
  }
}

export async function openFocusedFile(): Promise<void> {
  await resolveFocusedFileOpenTarget()?.();
}
