import { useEffect, useRef, type RefObject } from "react";

const MENU_POPUP_SELECTOR = '[data-slot="menubar-content"], [data-slot="menubar-sub-content"]';

export function useCompactMenuBarDismissal<T extends HTMLElement>(
  isOpen: boolean,
  containerRef: RefObject<T | null>,
  onDismiss: () => void,
  focusTargetRef: RefObject<HTMLElement | null>,
): void {
  const shouldRestoreFocusRef = useRef(false);

  useEffect(() => {
    if (isOpen || !shouldRestoreFocusRef.current) return;

    shouldRestoreFocusRef.current = false;
    focusTargetRef.current?.focus();
  }, [focusTargetRef, isOpen]);

  useEffect(() => {
    if (!isOpen) return;

    const handlePointerDown = (event: PointerEvent) => {
      const target = event.target;
      if (!(target instanceof Node)) return;
      if (containerRef.current?.contains(target)) return;

      if (target instanceof Element && target.closest(MENU_POPUP_SELECTOR)) return;

      onDismiss();
    };

    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key !== "Escape") return;

      event.preventDefault();
      event.stopPropagation();
      shouldRestoreFocusRef.current = true;
      onDismiss();
    };

    document.addEventListener("pointerdown", handlePointerDown, true);
    document.addEventListener("keydown", handleKeyDown, true);

    return () => {
      document.removeEventListener("pointerdown", handlePointerDown, true);
      document.removeEventListener("keydown", handleKeyDown, true);
    };
  }, [containerRef, focusTargetRef, isOpen, onDismiss]);
}
