import * as monaco from "monaco-editor/esm/vs/editor/editor.api.js";
import { Action } from "monaco-editor/esm/vs/base/common/actions.js";
import { StandaloneServices } from "monaco-editor/esm/vs/editor/standalone/browser/standaloneServices.js";
import { IContextMenuService } from "monaco-editor/esm/vs/platform/contextview/browser/contextView.js";

type Entry = {
  model: monaco.editor.ITextModel; revision: number; chain: Promise<unknown>;
  readonly: boolean; frozen: boolean; closingHolds?: number;
};
type EditorAction = { id: string; line: number; endLine: number; title: string; icon: string };
type State = {
  generation: number; version: number; revision: number; batch?: string;
  actions: EditorAction[]; decorations: string[]; timer?: ReturnType<typeof setTimeout>;
};

/** Presentation only: opaque action keys route back to a versioned host list. */
export function attachPluginEditorActions<E extends Entry>(host: {
  entries(): Map<string, E>;
  editors(): monaco.editor.IStandaloneCodeEditor[];
  request(payload: object): Promise<any>;
  current(id: string, entry: E): () => boolean;
  lineNumbersFirst: boolean;
}) {
  const states = new Map<E, State>();
  let disposed = false;
  const get = (entry: E): State => {
    const found = states.get(entry);
    if (found) return found;
    const state: State = { generation: 0, version: 0, revision: 0, actions: [], decorations: [] };
    states.set(entry, state);
    entry.model.onWillDispose(() => { clearTimeout(state.timer); state.generation++; states.delete(entry); });
    return state;
  };
  async function refreshOne(id: string, entry: E) {
    const state = get(entry), generation = ++state.generation, version = entry.model.getVersionId();
    clearTimeout(state.timer);
    await entry.chain;
    const current = host.current(id, entry), revision = entry.revision;
    if (disposed || entry.model.isDisposed() || !current() || entry.readonly) return;
    const result = await host.request({ type: "pluginEditorActions", id, revision });
    if (disposed || !current() || state.generation !== generation || result.cancelled || entry.model.getVersionId() !== version) return;
    const actions: EditorAction[] = (Array.isArray(result.actions) ? result.actions : []).filter((item: EditorAction) =>
      typeof item?.id === "string" && typeof item.title === "string" &&
      Number.isInteger(item.line) && item.line >= 1 && item.line <= entry.model.getLineCount());
    // Multiple actions on one line share a popup rather than overwriting one another.
    const lines = [...new Map(actions.map(item => [item.line, item])).values()];
    state.decorations = entry.model.deltaDecorations(state.decorations, lines.map(item => ({
      range: new monaco.Range(item.line, 1, item.line, 1), options: {
        glyphMarginClassName: `lithe-plugin-editor-action lithe-java-run-${item.icon}`,
        linesDecorationsClassName: host.lineNumbersFirst ? `lithe-plugin-editor-action lithe-java-run-${item.icon}` : undefined,
        linesDecorationsTooltip: item.title,
        glyphMargin: { position: monaco.editor.GlyphMarginLane.Right },
        glyphMarginHoverMessage: { value: item.title.replace(/[\\`*_{}\[\]()#+.!<>|]/g, "\\$&"), isTrusted: false },
      },
    })));
    Object.assign(state, { version, revision, batch: result.batch, actions });
  }
  function schedule(id: string, entry: E) {
    const state = get(entry);
    clearTimeout(state.timer); state.generation++; state.actions = []; state.batch = undefined;
    if (!entry.model.isDisposed()) state.decorations = entry.model.deltaDecorations(state.decorations, []);
    state.timer = setTimeout(() => { void refreshOne(id, entry).catch(console.error); }, 180);
  }
  return {
    schedule,
    async refresh() {
      for (const [entry, state] of states) {
        clearTimeout(state.timer); state.generation++; state.actions = []; state.batch = undefined;
        if (!entry.model.isDisposed()) state.decorations = entry.model.deltaDecorations(state.decorations, []);
      }
      await Promise.all([...host.entries()].filter(([, entry]) => host.editors().some(view => view.getModel() === entry.model))
        .map(([id, entry]) => refreshOne(id, entry)));
    },
    attach(view: monaco.editor.IStandaloneCodeEditor) {
      const mouse = view.onMouseDown(event => {
        const element = event.target.element?.closest(".lithe-plugin-editor-action");
        const pair = [...host.entries()].find(([, entry]) => entry.model === view.getModel());
        if (!element || !pair || !event.target.position || !event.event.leftButton) return;
        event.event.preventDefault(); event.event.stopPropagation();
        const [id, entry] = pair, state = states.get(entry), line = event.target.position.lineNumber;
        const current = host.current(id, entry);
        if (!state || !current() || entry.readonly || entry.frozen || entry.closingHolds ||
            state.version !== entry.model.getVersionId() || state.revision !== entry.revision) return;
        const batch = state.batch;
        const items = state.actions.filter(item => item.line === line).map(item => new Action(
          `lithe.pluginEditor.${item.id}`, item.title, undefined, true, async () => {
            if (!current() || states.get(entry)?.batch !== batch || entry.readonly) return;
            await host.request({ type: "pluginEditorAction", id, revision: state.revision, batch, action: item.id });
          }));
        if (items.length) StandaloneServices.get(IContextMenuService).showContextMenu({
          getAnchor: () => ({ x: event.event.posx, y: event.event.posy }), getActions: () => items,
        });
      });
      const mouseUp = (event: MouseEvent) => {
        if ((event.target as Element | null)?.closest(".lithe-plugin-editor-action") && view.getDomNode()?.contains(event.target as Node))
          event.stopPropagation();
      };
      document.addEventListener("mouseup", mouseUp, true);
      view.onDidDispose(() => { mouse.dispose(); document.removeEventListener("mouseup", mouseUp, true); });
    },
    dispose() {
      disposed = true;
      for (const state of states.values()) { clearTimeout(state.timer); state.generation++; }
      states.clear();
    },
  };
}
