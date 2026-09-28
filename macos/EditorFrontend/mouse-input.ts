/** Correct WebKit's released-button mousedown before Monaco starts pointer tracking. */
export function installWebKitMouseInput(document: Document): { dispose(): void } {
  const mouseDown = (event: MouseEvent) => {
    if (event.buttons !== 0 || (event.button !== 0 && event.button !== 1) ||
        !(event.target instanceof Element) || !event.target.closest(".monaco-editor")) return;

    // Some IMEs reorder tap-to-click's mouseup before mousedown (WebKit #219670).
    // Monaco 0.55.1 compares later pointermove.buttons with this initial mask;
    // starting at zero makes unpressed hover movements extend the selection.
    // Keep the original event, click count, modifiers and upstream selection logic.
    Object.defineProperty(event, "buttons", { value: event.button === 0 ? 1 : 4 });
  };
  document.addEventListener("mousedown", mouseDown, true);
  return { dispose: () => document.removeEventListener("mousedown", mouseDown, true) };
}
