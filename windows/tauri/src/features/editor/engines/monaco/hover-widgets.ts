import { EDITOR_CONSTANTS } from "@/features/editor/config/constants";

const MONACO_HOVER_MIN_WIDTH = 120;
const MONACO_HOVER_MAX_WIDTH = 720;
const MONACO_HOVER_MIN_HEIGHT = 48;
const HOVER_MAX_WIDTH_PROPERTY = "--lithe-monaco-hover-max-width";
const MONACO_HOVER_WIDGET_SELECTOR =
  '[widgetid="editor.contrib.resizableContentHoverWidget"], [widgetid="editor.contrib.modesGlyphHoverWidget"]';

function isWithinMonacoHoverWidget(node: Node): boolean {
  if (!(node instanceof Element)) return false;
  return (
    node.matches(MONACO_HOVER_WIDGET_SELECTOR) ||
    node.closest(MONACO_HOVER_WIDGET_SELECTOR) !== null
  );
}

export function mutationsContainMonacoHoverWidget(mutations: readonly MutationRecord[]): boolean {
  return mutations.some((mutation) => {
    if (isWithinMonacoHoverWidget(mutation.target)) return true;
    return Array.from(mutation.addedNodes).some(
      (node) =>
        isWithinMonacoHoverWidget(node) ||
        (node instanceof Element && node.querySelector(MONACO_HOVER_WIDGET_SELECTOR) !== null),
    );
  });
}

function setStyleProperty(
  element: HTMLElement,
  property: "background" | "border" | "boxShadow" | "maxHeight" | "maxWidth" | "width",
  value: string,
) {
  if (element.style[property] === value) return;
  element.style[property] = value;
}

function getMonacoHoverMaxWidth(container: HTMLElement) {
  const margin = EDITOR_CONSTANTS.HOVER_TOOLTIP_MARGIN;
  const availableWidth = Math.max(MONACO_HOVER_MIN_WIDTH, container.clientWidth - margin * 2);
  return Math.min(MONACO_HOVER_MAX_WIDTH, availableWidth);
}

function getMonacoHoverMaxHeight(container: HTMLElement) {
  const margin = EDITOR_CONSTANTS.HOVER_TOOLTIP_MARGIN;
  const availableHeight = Math.max(MONACO_HOVER_MIN_HEIGHT, container.clientHeight - margin * 2);
  return Math.min(EDITOR_CONSTANTS.HOVER_TOOLTIP_HEIGHT, availableHeight);
}

function getMonacoHoverContentWidth(nodes: Array<HTMLElement | null>) {
  return nodes.reduce((width, node) => {
    if (!node) return width;
    const contentWidth = Array.from(node.children).reduce(
      (childWidth, child) =>
        child instanceof HTMLElement ? Math.max(childWidth, child.scrollWidth) : childWidth,
      node.scrollWidth,
    );
    return Math.max(width, contentWidth);
  }, MONACO_HOVER_MIN_WIDTH);
}

/**
 * Clamps visible hover widgets to the editor. The width limit is a custom
 * property on each widget rather than the editor container: changing a custom
 * property restyles every element below it, and the container holds the whole
 * editor, so a container-level write cost a full editor restyle on each open
 * and resize. Without a hover there is nothing to read or write.
 */
export function clampMonacoHoverWidgets(container: HTMLElement) {
  const widgetNodes = container.querySelectorAll<HTMLElement>(MONACO_HOVER_WIDGET_SELECTOR);
  if (widgetNodes.length === 0) return;

  const maxWidth = getMonacoHoverMaxWidth(container);
  const maxHeight = getMonacoHoverMaxHeight(container);

  for (const widgetNode of widgetNodes) {
    if (widgetNode.style.getPropertyValue(HOVER_MAX_WIDTH_PROPERTY) !== `${maxWidth}px`) {
      widgetNode.style.setProperty(HOVER_MAX_WIDTH_PROPERTY, `${maxWidth}px`);
    }
    const hoverNode = widgetNode.querySelector<HTMLElement>(".monaco-hover") ?? widgetNode;
    const scrollNode = hoverNode.querySelector<HTMLElement>(".monaco-scrollable-element");
    const contentNode = hoverNode.querySelector<HTMLElement>(".monaco-hover-content");
    const nextWidth = Math.min(maxWidth, getMonacoHoverContentWidth([scrollNode, contentNode]));

    setStyleProperty(widgetNode, "background", "transparent");
    setStyleProperty(widgetNode, "border", "0");
    setStyleProperty(widgetNode, "boxShadow", "none");

    for (const node of [widgetNode, hoverNode, scrollNode, contentNode]) {
      if (!node) continue;
      setStyleProperty(node, "maxHeight", `${maxHeight}px`);
      setStyleProperty(node, "maxWidth", `${maxWidth}px`);
      if (node.getBoundingClientRect().width !== nextWidth) {
        setStyleProperty(node, "width", `${nextWidth}px`);
      }
    }
  }
}
