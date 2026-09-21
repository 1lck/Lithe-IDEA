import { useEffect, type RefObject } from "react";

export function useTabWheelScroll(ref: RefObject<HTMLDivElement | null>, enabled: boolean) {
  useEffect(() => {
    const container = ref.current;
    if (!container || !enabled) return;

    const handleWheel = (event: WheelEvent) => {
      if (event.ctrlKey || event.metaKey) return;
      const maxScrollLeft = container.scrollWidth - container.clientWidth;
      if (maxScrollLeft <= 0) return;

      const delta = event.deltaX || event.deltaY;
      const nextScrollLeft = Math.max(0, Math.min(container.scrollLeft + delta, maxScrollLeft));
      if (nextScrollLeft === container.scrollLeft) return;

      event.preventDefault();
      container.scrollLeft = nextScrollLeft;
    };

    // A non-passive listener prevents native horizontal scrolling from applying
    // the same wheel movement again after the tab strip handles it.
    container.addEventListener("wheel", handleWheel, { passive: false });
    return () => container.removeEventListener("wheel", handleWheel);
  }, [ref, enabled]);
}
