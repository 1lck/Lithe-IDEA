import { useEffect } from "react";
import { getProjectGradientColorIndex } from "@/features/window/utils/project-gradient";

const PROJECT_COLOR_ATTRIBUTE = "data-project-color";
const GRADIENT_X_PROPERTY = "--lithe-project-gradient-x";

/** Selects the Islands project gradient color for the active project (see project-gradient.css). */
export function useProjectGradientColor(projectPath: string | undefined) {
  useEffect(() => {
    const root = document.documentElement;
    if (!projectPath) {
      root.removeAttribute(PROJECT_COLOR_ATTRIBUTE);
      return;
    }

    root.setAttribute(PROJECT_COLOR_ATTRIBUTE, String(getProjectGradientColorIndex(projectPath)));
    return () => root.removeAttribute(PROJECT_COLOR_ATTRIBUTE);
  }, [projectPath]);
}

/**
 * Peaks the gradient at the center of the project widget icon, like IntelliJ's
 * ProjectWidgetGradientLocationService. Without a widget the CSS default (150px) applies.
 */
export function useProjectGradientAnchor(anchor: HTMLElement | null) {
  useEffect(() => {
    if (!anchor) return;

    const root = document.documentElement;
    let frame = 0;
    const update = () => {
      cancelAnimationFrame(frame);
      frame = requestAnimationFrame(() => {
        const rect = anchor.getBoundingClientRect();
        if (rect.width === 0) return;
        root.style.setProperty(GRADIENT_X_PROPERTY, `${Math.round(rect.left + rect.width / 2)}px`);
      });
    };

    update();
    // Title bar items before the widget (brand, menu bar) shift it without resizing it, so
    // watch every element laid out ahead of it up to the title bar.
    const observer = new ResizeObserver(update);
    observer.observe(anchor);
    for (
      let node: Element | null = anchor;
      node && !node.classList.contains("lithe-title-bar");
      node = node.parentElement
    ) {
      for (let sibling = node.previousElementSibling; sibling; sibling = sibling.previousElementSibling) {
        observer.observe(sibling);
      }
    }
    window.addEventListener("resize", update);

    return () => {
      cancelAnimationFrame(frame);
      observer.disconnect();
      window.removeEventListener("resize", update);
      root.style.removeProperty(GRADIENT_X_PROPERTY);
    };
  }, [anchor]);
}
