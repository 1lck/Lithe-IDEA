const FIND_WIDGET_CLOSE_BUTTON_SELECTOR =
  '.find-widget .button.codicon-widget-close[role="button"]';

/**
 * Prevents Monaco's delayed visual hover from repeatedly covering the find
 * widget close button on WebView2. The button keeps its accessible label,
 * keyboard behavior, click handler, and CSS hover state.
 */
export function suppressFindWidgetCloseButtonHover(container: HTMLElement): () => void {
  const handleMouseOver = (event: MouseEvent) => {
    const target = event.target;
    if (!(target instanceof Element)) return;
    if (!target.closest(FIND_WIDGET_CLOSE_BUTTON_SELECTOR)) return;

    event.stopPropagation();
  };

  container.addEventListener("mouseover", handleMouseOver, true);
  return () => container.removeEventListener("mouseover", handleMouseOver, true);
}
