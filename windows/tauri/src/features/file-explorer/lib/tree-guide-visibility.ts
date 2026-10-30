/**
 * Tree indent guides appear while a guide is hovered or the tree has keyboard
 * focus. CSS could say this with `.file-tree-container:has(:focus-visible)`
 * and `:has(.file-tree-guide:hover)`, but the browser cannot narrow those
 * selectors: every focus change in the window (opening a file moves focus from
 * the tree to the editor) restyled the whole tree, about 1,000 elements and
 * 85 ms per file open. These attributes let it restyle only the guides.
 */
const HOVER_ATTRIBUTE = "data-guide-hover";
const FOCUS_ATTRIBUTE = "data-guide-focus";
const TREE_SELECTOR = ".file-tree-container";
const GUIDE_SELECTOR = ".file-tree-guide";

let installed = false;

function treeOf(target: EventTarget | null): HTMLElement | null {
  return target instanceof Element ? target.closest<HTMLElement>(TREE_SELECTOR) : null;
}

function setAttribute(element: HTMLElement | null, name: string, on: boolean): void {
  if (!element || element.hasAttribute(name) === on) return;
  if (on) element.setAttribute(name, "");
  else element.removeAttribute(name);
}

/** Installs the document-level listeners once; later calls are no-ops. */
export function installTreeGuideVisibility(doc: Document = document): void {
  if (installed) return;
  installed = true;
  doc.addEventListener("pointerover", (event) => {
    const target = event.target;
    if (!(target instanceof Element) || !target.closest(GUIDE_SELECTOR)) return;
    setAttribute(treeOf(target), HOVER_ATTRIBUTE, true);
  });
  doc.addEventListener("pointerout", (event) => {
    const target = event.target;
    if (!(target instanceof Element) || !target.closest(GUIDE_SELECTOR)) return;
    const next = event.relatedTarget;
    if (next instanceof Element && next.closest(GUIDE_SELECTOR)) return;
    setAttribute(treeOf(target), HOVER_ATTRIBUTE, false);
  });
  doc.addEventListener("focusin", (event) => {
    const target = event.target;
    const tree = treeOf(target);
    if (!tree || !(target instanceof Element)) return;
    setAttribute(tree, FOCUS_ATTRIBUTE, target.matches(":focus-visible"));
  });
  doc.addEventListener("focusout", (event) => {
    const tree = treeOf(event.target);
    if (!tree) return;
    const next = event.relatedTarget;
    if (next instanceof Node && tree.contains(next)) return;
    setAttribute(tree, FOCUS_ATTRIBUTE, false);
  });
}

export function resetTreeGuideVisibilityForTests(): void {
  installed = false;
}
