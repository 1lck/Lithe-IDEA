import { Action, ActionRunner, Separator, SubmenuAction } from "monaco-editor/esm/vs/base/common/actions.js";
import { installNativeContextMenu, type MenuDelegate, type MenuHandler, type NativeMenuItem } from "../../EditorFrontend/context-menu";
const assert = (condition: unknown, message: string) => { if (!condition) throw new Error(message); };

function harness() {
  const requests: { payload: { items: NativeMenuItem[]; x: number; y: number }; resolve: (value: { selected: string | null; handled?: boolean }) => void; reject: (error: Error) => void }[] = [];
  const errors: unknown[] = [], hidden: boolean[] = [], log: unknown[] = [];
  let focusCount = 0;
  const handler: MenuHandler = {
    showContextMenu() { throw new Error("Web menu must not render"); },
    keybindingService: { lookupKeybinding: () => ({ getLabel: () => "F12" }) },
    telemetryService: { publicLog2: (_event, data) => log.push(data) },
    onDidActionRun: event => { if (event.error) errors.push(event.error); },
  };
  const original = handler.showContextMenu;
  const menu = installNativeContextMenu(handler, payload => new Promise((resolve, reject) => requests.push({ payload, resolve, reject })),
    { activeElement: { focus: () => focusCount++ } } as unknown as Document);
  const show = (actions: MenuDelegate["getActions"], extra: Partial<MenuDelegate> = {}) => handler.showContextMenu({
    getActions: actions, getAnchor: () => ({ posx: 10, posy: 20 }), onHide: cancelled => hidden.push(cancelled), ...extra,
  });
  return { menu, handler, original, requests, hidden, errors, log, show, focusCount: () => focusCount };
}
// Replies are controlled explicitly. The enclosing WebKit probe owns a bounded deadline.
const flush = async () => { for (let i = 0; i < 8; i++) await Promise.resolve(); };

export const contextMenuCases = [{ name: "native clipboard selection does not execute a second DOM command", run: async () => {
  const h = harness();
  let calls = 0;
  try {
    h.show(() => [new Action("editor.action.clipboardCutAction", "Cut", undefined, true, () => { calls++; })]);
    h.requests[0].resolve({ selected: "0", handled: true }); await flush();
    assert(calls === 0 && JSON.stringify(h.hidden) === "[false]", "native cut executed twice or was treated as cancellation");
    assert(h.focusCount() === 1, "native clipboard selection lost editor focus");
  } finally { h.menu.dispose(); }
}}, { name: "native menu preserves resolved actions, groups, bindings, context and runner", run: async () => {
  const h = harness(), runner = new ActionRunner();
  const calls: unknown[] = [];
  const action = new Action("editor.action.clipboardCopyAction", "Copy", undefined, true, context => { calls.push(context); });
  action.checked = true;
  const disabled = new Action("disabled", "Unavailable", undefined, false, () => { throw new Error("disabled"); });
  const child = new Action("vs.editor.ICodeEditor:7:lithe.javaRun.run", "Existing child", undefined, true, () => {});
  let upstreamRuns = 0;
  const subscription = runner.onDidRun(() => upstreamRuns++);
  try {
    h.show(() => [action, new Separator(), disabled, new SubmenuAction("more", "More", [child])], {
      actionRunner: runner, getActionsContext: () => "original context", getKeyBinding: () => ({ getLabel: () => "⌘C" }),
    });
    const request = h.requests[0];
    assert(request.payload.x === 10, "request.payload.x"); assert(request.payload.y === 20, "request.payload.y");
    assert(JSON.stringify(request.payload.items.map(item => item.id)) === JSON.stringify([action.id, Separator.ID, "disabled", "more"]), "request.payload.items.map(item => item.id)");
    assert(request.payload.items[0].checked && request.payload.items[0].shortcut === "⌘C", "lost checked state or delegate keybinding");
    assert(request.payload.items[2].enabled === false, "request.payload.items[2].enabled");
    assert(request.payload.items[3].children?.[0].id === "lithe.javaRun.run", "request.payload.items[3].children?.[0].id");
    request.resolve({ selected: request.payload.items[0].key }); await flush();
    assert(JSON.stringify(calls) === JSON.stringify(["original context"]), "calls");
    assert(JSON.stringify(h.hidden) === "[false]", "selected action reported cancellation");
    assert(upstreamRuns === 1 && h.focusCount() === 1, "original runner or focus restoration skipped");
    assert(JSON.stringify(h.log) === JSON.stringify([{ id: action.id, from: "contextMenu" }]), "h.log");
  } finally { subscription.dispose(); runner.dispose(); h.menu.dispose(); }
}}, { name: "native menu replacement and disposal reject stale selections", run: async () => {
  const h = harness(); let calls = 0;
  const action = new Action("existing", "Existing", undefined, true, () => { calls++; });
  try {
    h.show(() => [action]); h.show(() => [action]);
    h.requests[0].resolve({ selected: "0" }); await flush();
    assert(calls === 0, "calls"); assert(JSON.stringify(h.hidden) === JSON.stringify([true]), "h.hidden");
    h.menu.dispose(); h.requests[1].resolve({ selected: "0" }); await flush();
    assert(calls === 0, "calls"); assert(JSON.stringify(h.hidden) === JSON.stringify([true, true]), "h.hidden");
    assert(h.handler.showContextMenu === h.original, "h.handler.showContextMenu");
  } finally { h.menu.dispose(); }
}}, { name: "native menu cancellation and failures clear the original delegate", run: async () => {
  const h = harness(); let calls = 0;
  const disabled = new Action("disabled", "Disabled", undefined, false, () => { calls++; });
  try {
    h.show(() => []); assert(h.requests.length === 0, "h.requests.length");
    for (const selected of [null, "unknown", "0"]) {
      h.show(() => [disabled]); h.requests.at(-1)!.resolve({ selected }); await flush();
    }
    h.show(() => [disabled]); h.requests.at(-1)!.reject(new Error("host closed")); await flush();
    assert(calls === 0, "calls"); assert(h.errors.length === 1, "h.errors.length"); assert(h.hidden.length === 5, "h.hidden.length");
    assert(h.focusCount() === 0, "h.focusCount()");
  } finally { h.menu.dispose(); }
}}];
