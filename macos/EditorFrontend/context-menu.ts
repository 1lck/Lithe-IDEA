import { ActionRunner, Separator, SubmenuAction, type IAction } from "monaco-editor/esm/vs/base/common/actions.js";

export interface NativeMenuItem {
  key: string;
  id: string;
  title: string;
  enabled: boolean;
  checked: boolean;
  shortcut?: string;
  separator?: boolean;
  children?: NativeMenuItem[];
}
interface Keybinding { getLabel(): string | null; }
export interface MenuDelegate {
  getActions(): readonly IAction[];
  getAnchor(): { x: number; y: number } | { posx: number; posy: number } | HTMLElement;
  getKeyBinding?(action: IAction): Keybinding | undefined;
  getActionsContext?(): unknown;
  actionRunner?: ActionRunner;
  skipTelemetry?: boolean;
  onHide?(cancelled: boolean): void;
}
export interface MenuHandler {
  showContextMenu(delegate: MenuDelegate): void;
  keybindingService: { lookupKeybinding(id: string): Keybinding | undefined };
  telemetryService: { publicLog2(event: string, data: unknown): void };
  onDidActionRun(event: { error?: unknown }): void;
}

/** Replace only Monaco 0.55.1's renderer, after its menu/context-key resolution. */
export function installNativeContextMenu(handler: MenuHandler,
  request: (payload: { type: "contextMenu"; x: number; y: number; items: NativeMenuItem[] }) => Promise<{ selected: string | null; handled?: boolean }>,
  document: Document): { dispose(): void } {
  const original = handler.showContextMenu;
  let cancelCurrent: (() => void) | undefined;
  let disposed = false;
  handler.showContextMenu = delegate => {
    cancelCurrent?.();
    const actions = delegate.getActions();
    if (!actions.length || disposed) { delegate.onHide?.(true); return; }
    const selectedActions = new Map<string, IAction>();
    const serialize = (values: readonly IAction[]): NativeMenuItem[] => values.map(action => {
      const key = String(selectedActions.size);
      selectedActions.set(key, action);
      const binding = delegate.getKeyBinding ? delegate.getKeyBinding(action) : handler.keybindingService.lookupKeybinding(action.id);
      // Standalone editor.addAction prefixes only custom IDs with its view identity.
      return { key, id: action.id.replace(/^vs\.editor\.ICodeEditor:\d+:/, ""), title: action.label, enabled: action.enabled, checked: action.checked === true,
        shortcut: binding?.getLabel() ?? undefined, separator: action.id === Separator.ID,
        children: action instanceof SubmenuAction ? serialize(action.actions) : undefined };
    });
    const items = serialize(actions);
    const anchor = delegate.getAnchor();
    const point = "getBoundingClientRect" in anchor ? (() => {
      const bounds = anchor.getBoundingClientRect();
      return { x: bounds.left, y: bounds.bottom };
    })() : "posx" in anchor ? { x: anchor.posx, y: anchor.posy } : anchor;
    const focused = document.activeElement as HTMLElement | null;
    let hidden = false;
    const hide = (cancelled: boolean) => {
      if (hidden) return;
      hidden = true;
      if (cancelCurrent === cancel) cancelCurrent = undefined;
      delegate.onHide?.(cancelled);
    };
    const cancel = () => hide(true);
    cancelCurrent = cancel;
    void request({ type: "contextMenu", x: point.x, y: point.y, items }).then(async result => {
      if (hidden || disposed) return;
      const action = result.selected === null ? undefined : selectedActions.get(result.selected);
      hide(!action?.enabled);
      if (!action?.enabled || action instanceof SubmenuAction || action.id === Separator.ID) return;
      focused?.focus();
      if (result.handled) return;
      const runner = delegate.actionRunner ?? new ActionRunner();
      const listener = runner.onDidRun(event => handler.onDidActionRun(event));
      try {
        if (!delegate.skipTelemetry) handler.telemetryService.publicLog2("workbenchActionExecuted", { id: action.id, from: "contextMenu" });
        await runner.run(action, delegate.getActionsContext?.() ?? null);
      } finally {
        listener.dispose();
        if (!delegate.actionRunner) runner.dispose();
      }
    }).catch(error => { hide(true); handler.onDidActionRun({ error }); });
  };
  return { dispose() {
    disposed = true;
    cancelCurrent?.();
    handler.showContextMenu = original;
  } };
}
