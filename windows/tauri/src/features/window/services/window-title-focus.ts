const SIDEBAR_SCOPE = '[data-external-file-drop-scope="sidebar"]';

interface TitleFocusDocument {
  readonly activeElement: Pick<Element, "closest"> | null;
  addEventListener: (type: "focusin" | "focusout", listener: () => void) => void;
  removeEventListener: (type: "focusin" | "focusout", listener: () => void) => void;
}

export function createWindowTitleFocus(
  document: TitleFocusDocument,
  schedule: (callback: () => void) => void = queueMicrotask,
) {
  const listeners = new Set<() => void>();
  let disposed = false;
  let scheduled = false;
  const readSidebarFocus = () => !!document.activeElement?.closest(SIDEBAR_SCOPE);
  let sidebarFocus = readSidebarFocus();
  const onFocus = () => {
    if (disposed || scheduled) return;
    scheduled = true;
    // 焦点转移完成后读取实际目标，避免离开和进入事件产生中间标题。
    schedule(() => {
      scheduled = false;
      if (disposed) return;
      const next = readSidebarFocus();
      if (next === sidebarFocus) return;
      sidebarFocus = next;
      for (const listener of listeners) listener();
    });
  };
  document.addEventListener("focusin", onFocus);
  document.addEventListener("focusout", onFocus);
  return {
    isSidebarFocused: () => {
      sidebarFocus = readSidebarFocus();
      return sidebarFocus;
    },
    subscribe: (listener: () => void) => {
      listeners.add(listener);
      return () => { listeners.delete(listener); };
    },
    dispose: () => {
      disposed = true;
      listeners.clear();
      document.removeEventListener("focusin", onFocus);
      document.removeEventListener("focusout", onFocus);
    },
  };
}
