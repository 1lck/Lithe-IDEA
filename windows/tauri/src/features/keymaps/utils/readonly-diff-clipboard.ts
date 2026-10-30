/**
 * Read-only diff surfaces keep the clipboard to themselves.
 *
 * Their Monaco diff editors hold the selection the user can see, while the
 * editor command copies from the source editor's model. Intercepting Ctrl+C
 * there replaced a working copy with nothing (or with unrelated text), so the
 * keymap leaves copy and cut to the browser inside these surfaces.
 */
export function shouldDeferClipboardToReadOnlyDiff(
  event: KeyboardEvent,
  target: EventTarget | null,
  activeElement: EventTarget | null,
): boolean {
  if (event.altKey || event.shiftKey || !(event.ctrlKey || event.metaKey)) return false;

  const key = event.key.toLowerCase();
  if (key !== "c" && key !== "x") return false;

  const insideReadOnlyDiff = (node: EventTarget | null) => {
    const element = node as { closest?: (selector: string) => unknown } | null;
    return (
      typeof element?.closest === "function" && element.closest("[data-readonly-diff]") !== null
    );
  };

  return insideReadOnlyDiff(target) || insideReadOnlyDiff(activeElement);
}
