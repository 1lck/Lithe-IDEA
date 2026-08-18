import type { MouseEvent } from "react";

type TitleBarMouseDownEvent = Pick<
  MouseEvent<HTMLDivElement>,
  "button" | "currentTarget" | "target"
>;

const INTERACTIVE_TARGET_SELECTOR =
  "button, a, input, textarea, select, [role='tab'], [contenteditable='true']";

export function runTitleBarDrag(
  event: TitleBarMouseDownEvent,
  startDragging: () => void,
): boolean {
  if (event.button !== 0) return false;

  const target = event.target as HTMLElement;
  if (!event.currentTarget.contains(target)) return false;
  if (target.closest(INTERACTIVE_TARGET_SELECTOR)) return false;

  startDragging();
  return true;
}
