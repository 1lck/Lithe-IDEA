import { expect, test } from "bun:test";
import { createWindowTitleFocus } from "./window-title-focus";

test("observes existing sidebar scope after coalesced focus transfer and cleans up", () => {
  const scheduled: Array<() => void> = [];
  const handlers = new Map<string, () => void>();
  const selectors: string[] = [];
  let inside = false;
  const focus = createWindowTitleFocus({
    activeElement: { closest: (selector: string) => {
      selectors.push(selector);
      return inside ? {} as Element : null;
    } },
    addEventListener: (event, listener) => { handlers.set(event, listener); },
    removeEventListener: (event) => { handlers.delete(event); },
  }, (callback) => scheduled.push(callback));
  let changes = 0;
  const stop = focus.subscribe(() => { changes++; });
  const flush = () => { while (scheduled.length) scheduled.shift()!(); };
  try {
    inside = true;
    handlers.get("focusout")!(); handlers.get("focusin")!();
    expect(scheduled).toHaveLength(1);
    flush();
    expect(focus.isSidebarFocused()).toBe(true);
    expect(changes).toBe(1);
    handlers.get("focusin")!(); flush();
    expect(changes).toBe(1);
    inside = false; handlers.get("focusin")!(); flush();
    expect(changes).toBe(2);
    inside = true; handlers.get("focusin")!();
    stop(); focus.dispose(); flush();
    expect(changes).toBe(2);
    expect(handlers.size).toBe(0);
    expect(selectors.every((selector) => selector === '[data-external-file-drop-scope="sidebar"]')).toBe(true);
  } finally {
    stop(); focus.dispose(); flush();
  }
});

test("no focused element is treated as outside the sidebar", () => {
  const focus = createWindowTitleFocus({
    activeElement: null,
    addEventListener: () => {}, removeEventListener: () => {},
  });
  try { expect(focus.isSidebarFocused()).toBe(false); }
  finally { focus.dispose(); }
});
