import * as monaco from "monaco-editor/esm/vs/editor/editor.api.js";
import { Action } from "monaco-editor/esm/vs/base/common/actions.js";
import { StandaloneServices } from "monaco-editor/esm/vs/editor/standalone/browser/standaloneServices.js";
import { IContextMenuService } from "monaco-editor/esm/vs/platform/contextview/browser/contextView.js";
import { actionChoices, actionMarkers, normalizeEditorActions, type ActionLane, type EditorAction } from "./plugin-editor-action-rules";

type Entry = {
  model: monaco.editor.ITextModel; revision: number; chain: Promise<unknown>;
  readonly: boolean; frozen: boolean; closingHolds?: number;
};
type State = {
  generation: number; version: number; revision: number; batch?: string;
  actions: EditorAction[]; decorations: string[]; timer?: ReturnType<typeof setTimeout>;
  /** Whether the last list had a navigation marker; kept across edits so the gutter does not jump. */
  navigation: boolean;
};

const LANE_CLASS_PREFIX = "lithe-editor-action-lane-";

/** Presentation only: opaque action keys route back to a versioned host list. */
export function attachPluginEditorActions<E extends Entry>(host: {
  entries(): Map<string, E>;
  editors(): monaco.editor.IStandaloneCodeEditor[];
  request(payload: object): Promise<any>;
  current(id: string, entry: E): () => boolean;
  lineNumbersFirst: boolean;
  /** Called after an entry's markers changed, so the gutter can make room for the left lane. */
  changed?(entry: E): void;
}) {
  const states = new Map<E, State>();
  let disposed = false;
  const get = (entry: E): State => {
    const found = states.get(entry);
    if (found) return found;
    const state: State = { generation: 0, version: 0, revision: 0, actions: [], decorations: [], navigation: false };
    states.set(entry, state);
    entry.model.onWillDispose(() => { clearTimeout(state.timer); state.generation++; states.delete(entry); });
    return state;
  };
  // Without a current list the model shows no markers and nothing is clickable.
  const forget = (entry: E, state: State) => {
    clearTimeout(state.timer); state.generation++; state.actions = []; state.batch = undefined;
    if (!entry.model.isDisposed()) state.decorations = entry.model.deltaDecorations(state.decorations, []);
  };
  async function refreshOne(id: string, entry: E) {
    const state = get(entry), generation = ++state.generation, version = entry.model.getVersionId();
    clearTimeout(state.timer);
    await entry.chain;
    const current = host.current(id, entry), revision = entry.revision;
    if (disposed || entry.model.isDisposed() || !current() || entry.readonly) return;
    const result = await host.request({ type: "pluginEditorActions", id, revision });
    if (disposed || !current() || state.generation !== generation || result.cancelled || entry.model.getVersionId() !== version) return;
    const actions = normalizeEditorActions(result.actions, entry.model.getLineCount());
    // Actions of one line and lane share a popup rather than overwriting one another.
    state.decorations = entry.model.deltaDecorations(state.decorations, actionMarkers(actions).map(marker => {
      const classes = `lithe-editor-action lithe-editor-action-${marker.icon} ${LANE_CLASS_PREFIX}${marker.lane}`;
      return {
        range: new monaco.Range(marker.line, 1, marker.line, 1), options: {
          glyphMarginClassName: classes,
          linesDecorationsClassName: host.lineNumbersFirst ? classes : undefined,
          linesDecorationsTooltip: marker.title,
          glyphMargin: { position: marker.lane === "left" ? monaco.editor.GlyphMarginLane.Left : monaco.editor.GlyphMarginLane.Right },
          glyphMarginHoverMessage: { value: marker.title.replace(/[\\`*_{}\[\]()#+.!<>|]/g, "\\$&"), isTrusted: false },
        },
      };
    }));
    Object.assign(state, { version, revision, batch: result.batch, actions,
      navigation: actions.some(action => action.icon.startsWith("navigate-")) });
    host.changed?.(entry);
  }
  function schedule(id: string, entry: E) {
    const state = get(entry);
    forget(entry, state);
    state.timer = setTimeout(() => { void refreshOne(id, entry).catch(console.error); }, 180);
  }
  return {
    schedule,
    /** Whether the entry's gutter needs the left lane for navigation markers. */
    hasNavigation: (entry: E) => states.get(entry)?.navigation === true,
    async refresh() {
      for (const [entry, state] of states) { forget(entry, state); state.navigation = false; host.changed?.(entry); }
      await Promise.all([...host.entries()].filter(([, entry]) => host.editors().some(view => view.getModel() === entry.model))
        .map(([id, entry]) => refreshOne(id, entry)));
    },
    attach(view: monaco.editor.IStandaloneCodeEditor) {
      const mouse = view.onMouseDown(event => {
        const element = event.target.element?.closest(".lithe-editor-action");
        const pair = [...host.entries()].find(([, entry]) => entry.model === view.getModel());
        if (!element || !pair || !event.target.position || !event.event.leftButton) return;
        event.event.preventDefault(); event.event.stopPropagation();
        const [id, entry] = pair, state = states.get(entry), line = event.target.position.lineNumber;
        const lane: ActionLane = element.classList.contains(`${LANE_CLASS_PREFIX}left`) ? "left" : "right";
        const current = host.current(id, entry);
        if (!state || !current() || entry.readonly || entry.frozen || entry.closingHolds ||
            state.version !== entry.model.getVersionId() || state.revision !== entry.revision) return;
        const batch = state.batch;
        const items = actionChoices(state.actions, line, lane).map(choice => new Action(
          `lithe.pluginEditor.${choice.key}`, choice.title, undefined, true, async () => {
            if (!current() || states.get(entry)?.batch !== batch || entry.readonly) return;
            await host.request({ type: "pluginEditorAction", id, revision: state.revision, batch,
              action: choice.action, ...(choice.alternative === undefined ? {} : { alternative: choice.alternative }) });
          }));
        if (items.length) StandaloneServices.get(IContextMenuService).showContextMenu({
          getAnchor: () => ({ x: event.event.posx, y: event.event.posy }), getActions: () => items,
        });
      });
      const mouseUp = (event: MouseEvent) => {
        if ((event.target as Element | null)?.closest(".lithe-editor-action") && view.getDomNode()?.contains(event.target as Node))
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
