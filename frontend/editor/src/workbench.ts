import { runEditorCommand } from "./editor-commands";
import { IBulkEditService } from "monaco-editor/esm/vs/editor/browser/services/bulkEditService.js";
import { StandaloneServices } from "monaco-editor/esm/vs/editor/standalone/browser/standaloneServices.js";
import { mountNativeFind, type NativeFindInput } from "./native-find";
import { mapCompletionKind } from "./completion-kind";
import { mountDiffReview, type DiffReviewInput, type ReviewSelection } from "./diff-review";
import * as monaco from "monaco-editor/esm/vs/editor/editor.api.js";
import "monaco-editor/esm/vs/editor/editor.all.js";
import { ensureMonacoLanguageTokenizer } from "./language-contributions";
import { toMonacoLanguageId } from "./language";
import { SourceText } from "./source-text";
import { toMonacoModelValue } from "./line-endings";
import { acquireMonacoModel } from "./model-lifecycle";
import { installThemes } from "./theme";
import { installJavaTextMate } from "./textmate";
import { Emitter } from "monaco-editor/esm/vs/base/common/event.js";
import { MONACO_SEMANTIC_TOKEN_LEGEND, encodeMonacoSemanticTokens } from "./semantic-tokens";
import { CancellationError, isCancellationError } from "monaco-editor/esm/vs/base/common/errors.js";
import { isMacintosh } from "monaco-editor/esm/vs/base/common/platform.js";

export interface WorkbenchHost {
  request(payload: object): Promise<any>;
  palette: { defaults: Record<string, { light: string; dark: string }> };
  javaNavigationIcons?: Record<"up-interface" | "up-inheritance" | "down-interface" | "down-inheritance", string>;
  keybindings?: { command: string; label: string; keybinding: number }[];
}

function languageForFilename(filename: string | undefined): string {
  if (!filename) return "plaintext";
  const name = filename.toLowerCase();
  const registered = monaco.languages.getLanguages();
  const exact = registered.find(language => language.filenames?.some(file => file.toLowerCase() === name));
  if (exact) return exact.id;
  return registered.flatMap(language => (language.extensions ?? []).map(extension => ({ id: language.id, extension })))
    .filter(language => name.endsWith(language.extension.toLowerCase()))
    .sort((left, right) => right.extension.length - left.extension.length)[0]?.id ?? "plaintext";
}

// Host capabilities are injected. The editor never imports a platform adapter.
export function mountWorkbench(host: WorkbenchHost) {
  type GitMarker = { id: string; line: number; kind: "added" | "modified" | "deleted"; stage: boolean; unstage: boolean; discard: boolean };
  type BlameLine = { line: number; commit: string; author: string; date: string };
  type JavaMarker = { id: string; line: number; direction: "up" | "down"; relation?: "interface" | "inheritance" };
  type Entry = { source: SourceText; model: monaco.editor.ITextModel; release: () => void; revision: number; chain: Promise<unknown>; readonly: boolean; frozen: boolean; freezeOperation?: string; pendingEdits: number; state: monaco.editor.ICodeEditorViewState | null; debugDecorations?: string[]; debugPaused?: boolean; debugGeneration?: number; closingHolds?: number; filename?: string; locationRevision: number; contextGeneration: number };
  const entries = new Map<string, Entry>();
  const workers: Worker[] = [];
  const closingOperations = new Map<string, { entry?: Entry; cancelled: boolean }>();
  let nativeFind: { view: monaco.editor.IStandaloneCodeEditor; model: monaco.editor.ITextModel;
    generation: number; input: NativeFindInput; search: ReturnType<typeof mountNativeFind>; changed: monaco.IDisposable; disposed: monaco.IDisposable } | undefined;
  let nativeFindGeneration = 0;
  let freezeSequence = 0;
  let lastFocusedView: monaco.editor.IStandaloneCodeEditor | undefined;
  let nativeFindFocusTarget: { id: string; view: monaco.editor.IStandaloneCodeEditor; model: monaco.editor.ITextModel } | undefined;
  function dismissNativeFind() {
    const previous = nativeFind;
    nativeFind = undefined;
    previous?.changed.dispose(); previous?.disposed.dispose(); previous?.search.dispose();
  }
  let active: string | undefined;
  let editor: monaco.editor.IStandaloneCodeEditor;
  let markdownScrollID: string | undefined;
  let markdownScrollTimer: ReturnType<typeof setTimeout> | undefined;
  let applyingMarkdownScroll = false;
  let lastMarkdownRatio: number | undefined;
  function preserveMarkdownScroll() {
    if (applyingMarkdownScroll || markdownScrollTimer !== undefined || lastMarkdownRatio === undefined ||
        !active || active !== markdownScrollID || editor.getModel() !== entries.get(active)?.model) return;
    applyingMarkdownScroll = true;
    try {
      const extent = Math.max(0, editor.getScrollHeight() - editor.getLayoutInfo().height);
      editor.setScrollTop(lastMarkdownRatio * extent, monaco.editor.ScrollType.Immediate);
    } finally { applyingMarkdownScroll = false; }
  }
  let review: ReturnType<typeof mountDiffReview> | undefined;
  type Surface = { editor: monaco.editor.IStandaloneCodeEditor; id: string; states: Map<string, monaco.editor.ICodeEditorViewState> };
  const surfaces = new Map<string, Surface>();
  const surfaceOperations = new Map<string, number>();
  type FindSnapshot = { searchString: string; replaceString: string; isRevealed: boolean; isReplaceRevealed: boolean;
    isRegex: boolean; wholeWord: boolean; matchCase: boolean; preserveCase: boolean };
  interface FindController extends monaco.editor.IEditorContribution {
    getState(): FindSnapshot & { change(value: FindSnapshot, moveCursor: boolean): void };
    start(options: object, state: FindSnapshot): Promise<void>;
  }
  const findController = (view: monaco.editor.ICodeEditor) => view.getContribution<FindController>("editor.contrib.findController");
  function captureFind(view: monaco.editor.ICodeEditor): FindSnapshot | undefined {
    const state = findController(view)?.getState();
    if (!state) return;
    // Copy values: the controller mutates its state while the preview is active.
    return { searchString: state.searchString, replaceString: state.replaceString,
      isRevealed: state.isRevealed, isReplaceRevealed: state.isReplaceRevealed,
      isRegex: state.isRegex, wholeWord: state.wholeWord, matchCase: state.matchCase, preserveCase: state.preserveCase };
  }
  let suspendedViews: { role: string; id: string | undefined; state: monaco.editor.ICodeEditorViewState | null;
    find: FindSnapshot | undefined; focused: boolean }[] | undefined;
  let displayOptions: monaco.editor.IStandaloneEditorConstructionOptions = {};
  const allEditors = () => [editor, ...[...surfaces.values()].map(surface => surface.editor)].filter(Boolean);
  function applyReadOnly(entry: Entry) {
    for (const view of allEditors()) {
      if (view.getModel() === entry.model) view.updateOptions({ readOnly: entry.readonly || !!entry.closingHolds || failed });
    }
  }
  const nextInputTurn = () => new Promise<void>(resolve => setTimeout(resolve, 0));
  async function drainInput(entry: Entry) {
    // WKWebView can deliver the native save/close request before a Monaco type
    // command queued by the preceding key event. Give already queued input two
    // browser task checkpoints, and drain every edit chain observed between
    // them, before the revision snapshot is taken.
    let passes = 0;
    for (; passes < 3; passes++) {
      await nextInputTurn();
      const version = entry.model.getVersionId();
      const chain = entry.chain;
      await chain;
      await nextInputTurn();
      if (entry.model.getVersionId() === version && entry.chain === chain && entry.pendingEdits === 0) break;
    }
    return Math.min(passes + 1, 3);
  }
  let updating = false;
  let failed = false;
  let activation: Promise<unknown> = Promise.resolve();
  let textmate: Awaited<ReturnType<typeof installJavaTextMate>>;
  const semanticChanges = new Emitter<void>();
  const codeVisionChanges = new Emitter<void>();
  let semanticGeneration = 0;
  const semanticCache = new WeakMap<Entry, { key: string; promise: Promise<any> }>();
  // Language service failures must never disable editing or the save barrier.
  async function languageRequest(payload: object) {
    try { return await send(payload); }
    catch (error) { console.warn("Language request failed", error); return { cancelled: true }; }
  }
  const openingMeasurements = new Set<() => void>();
  const navigationStates = new WeakMap<Entry, { generation: number; version: number; revision: number;
    markers: JavaMarker[]; decorations: string[]; timer?: ReturnType<typeof setTimeout> }>();
  const navigationContexts = new WeakMap<monaco.editor.IStandaloneCodeEditor, () => void>();
  async function refreshNavigation(id: string, entry: Entry) {
    let state = navigationStates.get(entry);
    if (!state) {
      state = { generation: 0, version: 0, revision: 0, markers: [], decorations: [] };
      navigationStates.set(entry, state);
      entry.model.onWillDispose(() => { clearTimeout(state!.timer); state!.generation++; });
    }
    clearTimeout(state.timer);
    const current = documentCheckpoint(id, entry);
    const generation = ++state.generation, version = entry.model.getVersionId();
    await entry.chain;
    const valid = () => current() && entries.get(id) === entry && !entry.model.isDisposed() &&
      entry.model.getVersionId() === version && state!.generation === generation;
    if (!valid()) return;
    const revision = entry.revision, language = entry.model.getLanguageId();
    const reply = language === "java"
      ? await languageRequest({ type: "javaNavigation", id, revision }) : { markers: [] };
    if (!valid() || entry.revision !== revision || entry.model.getLanguageId() !== language || reply.cancelled) return;
    const markers: JavaMarker[] = (reply.markers ?? []).filter((marker: JavaMarker) => marker.line >= 1 &&
      marker.line <= entry.model.getLineCount() && (marker.direction === "up" || marker.direction === "down"));
    const directionsByLine = new Map<number, Map<JavaMarker["direction"], JavaMarker>>();
    for (const marker of markers) {
      let directions = directionsByLine.get(marker.line);
      if (!directions) directionsByLine.set(marker.line, directions = new Map());
      if (!directions.has(marker.direction)) directions.set(marker.direction, marker);
    }
    state.decorations = entry.model.deltaDecorations(state.decorations, [...directionsByLine].map(([line, directions]) => {
      const direction = directions.size === 2 ? "both" : [...directions.keys()][0];
      const icons = [...directions.values()].map(marker => `lithe-java-navigation-${marker.direction}-${marker.relation === "interface" ? "interface" : "inheritance"}`).join(" ");
      return { range: new monaco.Range(line, 1, line, 1), options: {
        glyphMarginClassName: `lithe-java-navigation lithe-java-navigation-${direction} ${icons}`,
        glyphMargin: { position: monaco.editor.GlyphMarginLane.Left },
        glyphMarginHoverMessage: { value: direction === "up" ? "Go to super declaration" : direction === "down"
          ? "Go to implementations" : "Go to super declaration (left) or implementations (right)", isTrusted: false },
      } };
    }));
    Object.assign(state, { markers, version, revision });
    for (const view of allEditors()) navigationContexts.get(view)?.();
  }
  function scheduleNavigation(id: string, entry: Entry) {
    if (entry.model.getLanguageId() !== "java" && !navigationStates.has(entry)) return;
    const state = navigationStates.get(entry);
    if (!state) { void refreshNavigation(id, entry).catch(console.error); return; }
    clearTimeout(state.timer);
    state.generation++;
    state.timer = setTimeout(() => { void refreshNavigation(id, entry).catch(console.error); }, 180);
  }

  // Diagnostic-only, bounded frame sampling; never delay activation or LSP work
  // waiting for animation frames (which can be suspended in a hidden window).
  function measureOpening(metrics: Record<string, number | boolean>, started: number) {
    let frame = 0;
    let count = 0;
    let last = performance.now();
    let maxGap = 0;
    let longFrames = 0;
    const cancel = () => { cancelAnimationFrame(frame); clearTimeout(deadline); openingMeasurements.delete(cancel); };
    const finish = () => {
      cancel();
      void send({ type: "performance", metrics: { ...metrics, frames: count, maxFrameGapMs: maxGap,
        longFramesOver50Ms: longFrames, hidden: document.hidden } }).catch(console.error);
    };
    const deadline = setTimeout(finish, 1500);
    openingMeasurements.add(cancel);
    const tick = (now: number) => {
      count++;
      if (count === 1) metrics.firstAnimationFrameMs = now - started;
      const gap = now - last;
      maxGap = Math.max(maxGap, gap);
      if (gap > 50) longFrames++;
      last = now;
      frame = requestAnimationFrame(tick);
    };
    frame = requestAnimationFrame(tick);
  }
  async function send(payload: object): Promise<any> {
    let timer: ReturnType<typeof setTimeout>;
    if ("id" in payload && typeof payload.id === "string") {
      const entry = entries.get(payload.id);
      if (entry) payload = { ...payload, locationRevision: entry.locationRevision };
    }
    try {
      return await Promise.race([host.request(payload), new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error("Native editor request timed out")), 10_000);
      })]);
    } finally { clearTimeout(timer!); }
  }
  function fail(error: unknown) {
    failed = true;
    const banner = document.querySelector("#error") as HTMLElement;
    banner.style.display = "block";
    banner.textContent = `编辑器同步失败，请保留窗口和未保存内容：${String(error)}`;
    for (const view of allEditors()) view.updateOptions({ readOnly: true });
    void send({ type: "failure", message: String(error) }).catch(console.error);
  }
  addEventListener("unhandledrejection", event => {
    if (isCancellationError(event.reason)) { event.preventDefault(); return; }
    fail(event.reason);
  });

  async function prepareEntry(payload: any): Promise<Entry> {
    let entry = entries.get(payload.id);
    const language = payload.language ? toMonacoLanguageId(payload.language) : languageForFilename(payload.filename);
    if (!entry) {
      if (typeof payload.text !== "string") throw new Error("New model requires document text");
      await ensureMonacoLanguageTokenizer(language);
      // Close preparation and workspace edits can initialize the same document
      // outside the activation queue. Reuse the first owner's mirror/listener.
      entry = entries.get(payload.id);
    }
    if (!entry) {
      const acquired = acquireMonacoModel(payload.text, language, monaco.Uri.parse(`lithe://document/${payload.id}`));
      const model = acquired.model;
      // Monaco owns normalized editing coordinates; the source mirror preserves disk newlines.
      model.setEOL(monaco.editor.EndOfLineSequence.LF);
      entry = { source: new SourceText(payload.text, model.getAlternativeVersionId()), model, release: acquired.release, revision: payload.revision, chain: Promise.resolve(), readonly: payload.readonly, frozen: false, pendingEdits: 0, state: null, filename: payload.filename, locationRevision: payload.locationRevision ?? 0, contextGeneration: 0 };
      entries.set(payload.id, entry);
      const owned = entry;
      model.onDidChangeContent(event => {
        scheduleNavigation(payload.id, owned);
        if (updating) return;
        const baseRevision = owned.revision++;
        const changes = owned.source.apply(event.changes, model.getAlternativeVersionId());
        owned.pendingEdits++;
        owned.chain = owned.chain.then(async () => {
          const reply = await send({ type: "edit", id: payload.id, baseRevision, changes });
          if (reply.revision !== owned.revision && reply.revision !== baseRevision + 1) throw new Error("Edit revision mismatch");
        }).then(() => { owned.pendingEdits--; }, error => {
          owned.pendingEdits--;
          fail(error);
          throw error;
        });
      });
    } else {
      const languageChanged = (payload.language || payload.filename) && entry.model.getLanguageId() !== language;
      if (languageChanged || (payload.filename !== undefined && payload.filename !== entry.filename) ||
          (payload.locationRevision !== undefined && payload.locationRevision !== entry.locationRevision)) {
        // Invalidate before awaiting syntax loading. Rename away and back must
        // not revive an older request, even when its text version is unchanged.
        entry.contextGeneration++;
        if (payload.filename !== undefined) entry.filename = payload.filename;
        if (payload.locationRevision !== undefined) entry.locationRevision = payload.locationRevision;
      }
      if (languageChanged) {
        await ensureMonacoLanguageTokenizer(language);
        if (entries.get(payload.id) !== entry || entry.model.isDisposed()) throw new CancellationError();
        monaco.editor.setModelLanguage(entry.model, language);
      }
    }
    if (typeof payload.readonly === "boolean" && entry.readonly !== payload.readonly) {
      entry.readonly = payload.readonly;
      applyReadOnly(entry);
    }
    return entry;
  }

  async function activate(payload: any) {
    const started = performance.now();
    const previous = active && entries.get(active);
    if (previous) { previous.state = editor.saveViewState(); await previous.chain; }
    const reused = entries.has(payload.id);
    const modelStarted = performance.now();
    const entry = await prepareEntry(payload);
    await entry.chain;
    const modelMs = performance.now() - modelStarted;
    const attachStarted = performance.now();
    active = payload.id;
    editor.setModel(entry.model);
    scheduleNavigation(payload.id, entry);
    if (entry.state) editor.restoreViewState(entry.state);
    editor.updateOptions({ readOnly: entry.readonly || !!entry.closingHolds || failed });
    if (payload.focus) editor.focus();
    const metrics = { reused, modelMs, attachMs: performance.now() - attachStarted,
      lines: entry.model.getLineCount(), utf16Length: entry.model.getValueLength() };
    if (payload.measure) measureOpening(metrics, started);
    return metrics;
  }

  function documentCheckpoint(id: string, entry: Entry) {
    const revision = entry.revision, version = entry.model.getVersionId();
    const generation = entry.contextGeneration, language = entry.model.getLanguageId();
    return () => entries.get(id) === entry && !entry.model.isDisposed() && !failed &&
      entry.revision === revision && entry.model.getVersionId() === version &&
      entry.contextGeneration === generation && entry.model.getLanguageId() === language &&
      !entry.closingHolds && !entry.frozen;
  }

  function workspaceCheckpoint() {
    const current = [...entries].map(([id, entry]) => documentCheckpoint(id, entry));
    return () => current.every(valid => valid());
  }

  async function prepareWorkspaceChanges(changes: any[], valid: () => boolean) {
    const edits: monaco.languages.IWorkspaceTextEdit[] = [];
    for (const change of changes) {
      if (!valid()) throw new Error("Workspace edit result is no longer current.");
      const target = await prepareEntry(change);
      if (!valid() || target.readonly || target.frozen || !!target.closingHolds || target.revision !== change.revision || target.source.value !== change.text)
        throw new Error("Workspace edit target has changed.");
      for (const edit of change.edits) {
        if (!monaco.Range.equalsRange(edit.range, target.model.validateRange(edit.range)))
          throw new Error("Workspace edit range is outside the document.");
        edits.push({ resource: target.model.uri, versionId: target.model.getVersionId(), textEdit: edit });
      }
    }
    if (!valid()) throw new Error("Workspace edit result is no longer current.");
    return { edits };
  }

  const debugRunContexts = new WeakMap<monaco.editor.IStandaloneCodeEditor, monaco.editor.IContextKey<boolean>>();
  const gitStates = new WeakMap<Entry, { version: number; revision: number; markers: GitMarker[]; decorations: string[];
    blameVisible?: boolean; blame?: BlameLine[] }>();
  const gitContextUpdates = new WeakMap<monaco.editor.IStandaloneCodeEditor, () => void>();
  function attachGitInteractions(view: monaco.editor.IStandaloneCodeEditor) {
    const blameKey = view.createContextKey("litheGit.blame", false);
    let renderedBlame: object | undefined;
    const escapeHTML = (value: string) => value.replace(/[&<>"']/g, character =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[character]!);
    const blameContext = (line = view.getPosition()?.lineNumber) => {
      const pair = [...entries].find(([, entry]) => entry.model === view.getModel());
      if (!pair) return;
      const [id, entry] = pair, state = gitStates.get(entry);
      if (!state?.blameVisible || entry.model.isDisposed() || state.version !== entry.model.getVersionId() ||
          state.revision !== entry.revision || entry.frozen || entry.closingHolds || failed) return;
      return { id, entry, state, blame: state.blame?.find(value => value.line === line) };
    };
    const showBlame = async (line?: number) => {
      const value = blameContext(line);
      if (!value?.blame) return;
      await languageRequest({ type: "blameCommit", id: value.id, revision: value.state.revision,
        line: value.blame.line, commit: value.blame.commit });
    };
    view.addAction({ id: "lithe.git.blameCommit", label: "Show Blame Commit", precondition: "litheGit.blame",
      contextMenuGroupId: "git", run: () => showBlame() });
    const keys = Object.fromEntries(["show", "stage", "unstage", "discard"].map(action =>
      [action, view.createContextKey(`litheGit.${action}`, false)]));
    const current = (line = view.getPosition()?.lineNumber) => {
      const pair = [...entries].find(([, entry]) => entry.model === view.getModel());
      if (!pair) return;
      const [id, entry] = pair, state = gitStates.get(entry);
      if (!state || entry.model.isDisposed() || state.version !== entry.model.getVersionId() ||
          state.revision !== entry.revision || entry.frozen || entry.closingHolds || failed) return;
      const marker = state.markers.find(marker => marker.line === line);
      return marker ? { id, entry, state, marker } : undefined;
    };
    const refresh = () => {
      const blame = blameContext();
      blameKey.set(!!blame?.blame);
      if (renderedBlame !== blame?.state) {
        renderedBlame = blame?.state;
        const byLine = new Map(blame?.state.blame?.map(value => [value.line, value]));
        view.updateOptions(blame ? { lineNumbersMinChars: 26, lineNumbers: line => {
          const value = byLine.get(line);
          const firstVisibleLine = view.getVisibleRanges()[0]?.startLineNumber;
          const show = value && (line === firstVisibleLine || byLine.get(line - 1)?.commit !== value.commit);
          const label = value ? `${value.author} · ${value.date}` : "";
          const metadata = value ? `<span class="lithe-blame" title="${escapeHTML(`${label} · ${value.commit.slice(0, 8)}`)}">${show ? escapeHTML(label) : "&#8203;"}</span>` : "";
          return `${metadata}<span class="lithe-blame-line">${line}</span>`;
        } } : { lineNumbers: "on", lineNumbersMinChars: 5 });
      }
      const value = current();
      for (const action of ["show", "stage", "unstage", "discard"] as const)
        keys[action].set(!!value && (action === "show" || (!value.entry.readonly && value.marker[action])));
    };
    gitContextUpdates.set(view, refresh);
    const run = async (action: string, line?: number) => {
      const value = current(line);
      if (!value) return;
      await languageRequest({ type: "gitLineAction", id: value.id, revision: value.state.revision, marker: value.marker.id, action });
    };
    for (const [action, label] of [["show", "Show Change"], ["stage", "Stage Change"], ["unstage", "Unstage Change"], ["discard", "Discard Change"]]) {
      view.addAction({ id: `lithe.git.${action}`, label, precondition: `litheGit.${action}`,
        contextMenuGroupId: "git", run: () => run(action) });
    }
    view.onDidChangeCursorPosition(refresh);
    view.onDidChangeModel(refresh);
    view.onDidChangeModelContent(refresh);
    view.onMouseDown(event => {
      if (event.event.leftButton && event.target.position && event.target.element?.closest(".lithe-blame")) {
        event.event.preventDefault(); event.event.stopPropagation();
        void showBlame(event.target.position.lineNumber);
        return;
      }
      if (event.target.type !== monaco.editor.MouseTargetType.GUTTER_LINE_DECORATIONS || !event.target.position ||
          !event.target.element?.classList.contains("lithe-git-marker")) return;
      if (event.event.leftButton) {
        event.event.preventDefault(); event.event.stopPropagation();
        void run("show", event.target.position.lineNumber);
      } else if (event.event.rightButton) {
        view.setPosition(event.target.position);
        refresh();
      }
    });
    refresh();
  }
  function attachImagePaste(view: monaco.editor.IStandaloneCodeEditor) {
    // The inner view does not exist until a model is attached and is replaced
    // on tab switches. The editor container survives both transitions.
    const node = view.getContainerDomNode();
    const paste = (event: ClipboardEvent) => {
      // Capture the immutable File while the paste event has access to its data.
      // A later native clipboard read could import a different copied image.
      const image = [...(event.clipboardData?.items ?? [])]
        .find(item => item.kind === "file" && item.type.startsWith("image/"))?.getAsFile();
      if (!image) return;
      event.preventDefault();
      event.stopImmediatePropagation();
      const pair = [...entries].find(([, entry]) => entry.model === view.getModel());
      const selection = view.getSelection();
      if (!pair || !selection) return;
      const [id, entry] = pair;
      const current = documentCheckpoint(id, entry);
      const version = entry.model.getVersionId();
      let disposed = false;
      const lifetime = view.onDidDispose(() => { disposed = true; });
      const valid = () => !disposed && current() && entries.get(id) === entry && !entry.model.isDisposed() &&
        view.getModel() === entry.model && entry.model.getVersionId() === version &&
        !entry.readonly && !entry.frozen && !entry.closingHolds && !failed;
      const offset = entry.model.getOffsetAt(selection.getStartPosition());
      const length = entry.model.getOffsetAt(selection.getEndPosition()) - offset;
      void entry.chain.then(async () => {
        if (!valid()) return;
        const metadata = { id, revision: entry.revision, mimeType: image.type, filename: image.name, byteCount: image.size };
        const preparation = await send({ type: "prepareImagePaste", ...metadata });
        if (preparation.cancelled || !valid()) return;
        if (!Number.isSafeInteger(preparation.maximumByteCount) || image.size > preparation.maximumByteCount)
          throw new Error("Clipboard image exceeds the host's image size limit");
        const base64 = await new Promise<string>((resolve, reject) => {
          const reader = new FileReader();
          const timeout = setTimeout(() => reader.abort(), 10_000);
          reader.onload = () => {
            const value = String(reader.result);
            resolve(value.slice(value.indexOf(",") + 1));
          };
          reader.onerror = () => reject(reader.error ?? new Error("Could not read clipboard image"));
          reader.onabort = () => reject(new Error("Clipboard image read was cancelled or timed out"));
          const cleanup = () => { clearTimeout(timeout); reader.onload = reader.onerror = reader.onabort = reader.onloadend = null; };
          reader.onloadend = cleanup;
          try { reader.readAsDataURL(image); }
          catch (error) { cleanup(); reject(error); }
        });
        if (!valid()) return;
        const reply = await send({ type: "pasteImage", ...metadata, offset, length, base64 });
        if (reply.cancelled || typeof reply.text !== "string") return;
        if (!valid()) {
          await send({ type: "editorNotification", id, message: "Image saved, but the document changed before insertion. Paste again to insert it." });
          return;
        }
        view.pushUndoStop();
        view.executeEdits("lithe.pasteImage", [{ range: selection, text: toMonacoModelValue(reply.text), forceMoveMarkers: true }]);
        view.pushUndoStop();
      }).catch(error => {
        console.warn("Image paste failed", error);
        void send({ type: "editorNotification", id, message: `Could not paste image: ${String(error)}` }).catch(console.error);
      }).finally(() => lifetime.dispose());
    };
    node.addEventListener("paste", paste, true);
    view.onDidDispose(() => node.removeEventListener("paste", paste, true));
  }
  function attachDefinitionNavigation(view: monaco.editor.IStandaloneCodeEditor) {
    const navigate = async (position: monaco.IPosition | null) => {
      const pair = [...entries].find(([, entry]) => entry.model === view.getModel());
      if (!pair || !position) return;
      const [id, entry] = pair, current = documentCheckpoint(id, entry);
      await entry.chain;
      if (!current() || view.getModel() !== entry.model) return;
      await languageRequest({ type: "definition", id, revision: entry.revision,
        line: position.lineNumber - 1, column: position.column - 1 });
    };
    view.addAction({ id: "lithe.goToDefinition", label: "Go to Definition", keybindings: [monaco.KeyCode.F12],
      contextMenuGroupId: "navigation", contextMenuOrder: 1, run: () => navigate(view.getPosition()) });
    view.onMouseDown(event => {
      const gesture = event.event;
      if (!(isMacintosh ? gesture.metaKey : gesture.ctrlKey) || !gesture.leftButton || gesture.altKey || gesture.shiftKey ||
          event.target.type !== monaco.editor.MouseTargetType.CONTENT_TEXT || !event.target.position) return;
      gesture.preventDefault();
      gesture.stopPropagation();
      void navigate(event.target.position);
    });
  }

  function attachDebugInteractions(view: monaco.editor.IStandaloneCodeEditor) {
    const navigationKeys = { up: view.createContextKey("litheJava.up", false), down: view.createContextKey("litheJava.down", false) };
    const navigation = (line = view.getPosition()?.lineNumber) => {
      const pair = [...entries].find(([, entry]) => entry.model === view.getModel());
      if (!pair) return;
      const [id, entry] = pair, state = navigationStates.get(entry);
      if (!state || entry.model.isDisposed() || entry.model.getLanguageId() !== "java" || state.version !== entry.model.getVersionId() || state.revision !== entry.revision ||
          entry.frozen || entry.closingHolds || failed) return;
      return { id, entry, state, markers: state.markers.filter(marker => marker.line === line) };
    };
    const refresh = () => {
      const value = navigation();
      for (const direction of ["up", "down"] as const) navigationKeys[direction].set(!!value?.markers.some(marker => marker.direction === direction));
    };
    navigationContexts.set(view, refresh);
    view.onDidChangeCursorPosition(refresh); view.onDidChangeModel(refresh); view.onDidChangeModelContent(refresh);
    const navigate = async (direction: "up" | "down", line?: number) => {
      const value = navigation(line), marker = value?.markers.find(marker => marker.direction === direction);
      if (value && marker) await languageRequest({ type: "javaNavigationAction", id: value.id, revision: value.state.revision, marker: marker.id });
    };
    for (const direction of ["up", "down"] as const) view.addAction({
      id: `lithe.javaNavigation.${direction}`, label: direction === "up" ? "Go to Super Declaration" : "Go to Implementations",
      precondition: `litheJava.${direction}`, contextMenuGroupId: "navigation", run: () => navigate(direction),
    });
    view.onMouseDown(event => {
      const element = event.target.element?.closest(".lithe-java-navigation");
      if (!element || !event.target.position || !event.event.leftButton) return;
      event.event.preventDefault(); event.event.stopPropagation();
      const bounds = element.getBoundingClientRect();
      const up = element.classList.contains("lithe-java-navigation-up") ||
        element.classList.contains("lithe-java-navigation-both") && event.event.posx < bounds.left + bounds.width / 2;
      void navigate(up ? "up" : "down", event.target.position.lineNumber);
    });
    for (const binding of host.keybindings ?? []) {
      view.addAction({ id: `lithe.keybinding.${binding.command}`, label: binding.label,
        keybindings: [binding.keybinding], precondition: "editorTextFocus && !editorReadonly",
        run: () => view.trigger("lithe.keybinding", binding.command, null) });
    }
    attachGitInteractions(view);
    attachImagePaste(view);
    attachDefinitionNavigation(view);
    debugRunContexts.set(view, view.createContextKey("litheCanRunToCursor", false));
    function request(type: "toggleBreakpoint" | "editBreakpoint" | "runToCursor", line: number, column = 1) {
      const model = view.getModel();
      const pair = [...entries].find(([, entry]) => entry.model === model);
      if (!pair || pair[1].readonly || pair[1].frozen || !!pair[1].closingHolds || failed) return;
      const [id, entry] = pair;
      const version = entry.model.getVersionId();
      return entry.chain.then(async () => {
        if (entries.get(id) !== entry || entry.model.isDisposed() || entry.model.getVersionId() !== version ||
            entry.frozen || !!entry.closingHolds || failed) return;
        await send({ type, id, revision: entry.revision, line, column });
      }).catch(error => console.warn("Debug request failed", error));
    }
    view.addAction({ id: "lithe.runToCursor", label: "Run to Cursor",
      precondition: "litheCanRunToCursor", contextMenuGroupId: "debug", contextMenuOrder: 1,
      run: () => {
        const position = view.getPosition();
        return position ? request("runToCursor", position.lineNumber, position.column) : undefined;
      } });
    view.addCommand(monaco.KeyCode.F9, () => {
      const position = view.getPosition();
      if (position) request("toggleBreakpoint", position.lineNumber);
    });
    const attached = [...entries].find(([, entry]) => entry.model === view.getModel());
    if (attached) scheduleNavigation(...attached);
    refresh();
    return view.onMouseDown(event => {
      if (event.target.element?.closest(".lithe-java-navigation")) return;
      if (event.target.type !== monaco.editor.MouseTargetType.GUTTER_GLYPH_MARGIN || !event.target.position ||
          (!event.event.leftButton && !event.event.rightButton)) return;
      event.event.preventDefault();
      event.event.stopPropagation();
      request(event.event.rightButton ? "editBreakpoint" : "toggleBreakpoint", event.target.position.lineNumber);
    });
  }

  const api = {
    async markdownScroll(payload: { id: string; ratio?: number } | null) {
      await activation;
      clearTimeout(markdownScrollTimer); markdownScrollTimer = undefined;
      markdownScrollID = payload?.id;
      lastMarkdownRatio = undefined;
      if (!payload || active !== payload.id || !Number.isFinite(payload.ratio)) return;
      applyingMarkdownScroll = true;
      try {
        const extent = Math.max(0, editor.getScrollHeight() - editor.getLayoutInfo().height);
        editor.setScrollTop(Math.min(1, Math.max(0, payload.ratio!)) * extent, monaco.editor.ScrollType.Immediate);
        lastMarkdownRatio = Math.min(1, Math.max(0, payload.ratio!));
      } finally { applyingMarkdownScroll = false; }
    },
    async refreshJavaNavigation() {
      await activation;
      await Promise.all([...entries].filter(([, entry]) => allEditors().some(view => view.getModel() === entry.model))
        .map(([id, entry]) => refreshNavigation(id, entry)));
    },
    async gitState(id: string, state: { revision: number; markers: GitMarker[]; blameVisible?: boolean; blame?: BlameLine[] }) {
      await activation;
      const entry = entries.get(id);
      if (!entry) return;
      await entry.chain;
      if (entries.get(id) !== entry || entry.model.isDisposed() || entry.revision !== state.revision) return;
      const old = gitStates.get(entry);
      const markers = state.markers.filter(marker => marker.line >= 1 && marker.line <= entry.model.getLineCount());
      const decorations = entry.model.deltaDecorations(old?.decorations ?? [], markers.map(marker => ({
        range: new monaco.Range(marker.line, 1, marker.line, 1), options: {
          isWholeLine: true, linesDecorationsClassName: `lithe-git-marker lithe-git-${marker.kind}`,
          linesDecorationsTooltip: `${marker.kind} — click to show change`,
          stickiness: monaco.editor.TrackedRangeStickiness.NeverGrowsWhenTypingAtEdges,
        },
      })));
      gitStates.set(entry, { ...state, markers, version: entry.model.getVersionId(), decorations });
      for (const view of allEditors()) gitContextUpdates.get(view)?.();
    },
    codeVisionRefresh() { codeVisionChanges.fire(); },
    async showDiff(input: DiffReviewInput & { filename?: string }) {
      await activation;
      if (!review) {
        (document.getElementById("editor") as HTMLElement).style.display = "none";
        const container = document.createElement("div");
        container.id = "diff-review"; container.style.cssText = "position:absolute;inset:0";
        document.body.append(container);
        review = mountDiffReview(container, (hunkID, action) => {
          void send({ type: "diffAction", hunkID, action }).catch(fail);
        });
      }
      await review.update({ ...input, language: input.filename ? languageForFilename(input.filename) : input.language });
    },
    selectDiff(selection: ReviewSelection) { review?.select(selection); },
    configureDiff(options: monaco.editor.IDiffEditorOptions) { review?.configure(options); },
    hideDiff() {
      review?.dispose(); review = undefined;
      document.getElementById("diff-review")?.remove();
      (document.getElementById("editor") as HTMLElement).style.display = "";
    },
    async suspendMain() {
      await activation;
      if (suspendedViews) return;
      dismissNativeFind();
      suspendedViews = [{ role: "primary", id: active, state: editor.saveViewState(), find: captureFind(editor), focused: editor.hasTextFocus() },
        ...[...surfaces].map(([role, surface]) => ({ role, id: surface.id, state: surface.editor.saveViewState(), find: captureFind(surface.editor), focused: surface.editor.hasTextFocus() }))];
    },
    async restoreMain() {
      await activation;
      const saved = suspendedViews;
      suspendedViews = undefined;
      for (const item of saved ?? []) {
        const view = item.role === "primary" ? editor : surfaces.get(item.role)?.editor;
        if (!view || view.getModel() !== entries.get(item.id ?? "")?.model) continue;
        const controller = findController(view);
        if (item.find && controller) {
          if (item.find.isRevealed) {
            await controller.start({ forceRevealReplace: item.find.isReplaceRevealed,
              seedSearchStringFromSelection: "none", seedSearchStringFromNonEmptySelection: false,
              seedSearchStringFromGlobalClipboard: false, shouldFocus: 0, shouldAnimate: false,
              updateSearchScope: false, loop: view.getOption(monaco.editor.EditorOption.find).loop }, item.find);
          } else { controller.getState().change(item.find, false); }
        }
        if (item.state) view.restoreViewState(item.state);
        if (item.focused) view.focus();
      }
    },
    semanticRefresh() { semanticGeneration++; semanticChanges.fire(); void api.refreshJavaNavigation().catch(console.error); },
    tokenizationReady() { return textmate.whenReady(editor.getModel()); },
    tokenizationStatus() { return textmate.status(); },
    updateDocument(payload: { id: string; filename: string; locationRevision: number; readonly: boolean }) {
      activation = activation.then(async () => {
        if (!entries.has(payload.id)) return;
        const entry = await prepareEntry(payload);
        scheduleNavigation(payload.id, entry);
        semanticGeneration++; semanticChanges.fire(); codeVisionChanges.fire();
      });
      return activation;
    },
    activate(payload: any) {
      activation = activation.then(() => activate(payload)).catch(fail);
      return activation;
    },
    showSecondary(payload: any) {
      let container = document.getElementById("secondary-editor");
      if (!container) {
        container = document.createElement("div");
        container.id = "secondary-editor";
        container.style.cssText = "position:absolute;left:50%;top:0;width:50%;height:100%";
        document.body.append(container);
      }
      (document.getElementById("editor") as HTMLElement).style.width = "50%";
      return api.attachSurface("secondary", container, payload);
    },
    hideSecondary() {
      api.detachSurface("secondary");
      document.getElementById("secondary-editor")?.remove();
      (document.getElementById("editor") as HTMLElement).style.width = "100%";
      editor.focus();
    },
    attachSurface(surfaceID: string, container: HTMLElement, payload: any) {
      const operation = (surfaceOperations.get(surfaceID) ?? 0) + 1;
      surfaceOperations.set(surfaceID, operation);
      activation = activation.then(async () => {
        const entry = await prepareEntry(payload);
        if (surfaceOperations.get(surfaceID) !== operation) return;
        let surface = surfaces.get(surfaceID);
        if (!surface) {
          const view = monaco.editor.create(container, { ...displayOptions, model: null });
          attachDebugInteractions(view);
          surface = { editor: view, id: payload.id, states: new Map() };
          surfaces.set(surfaceID, surface);
          view.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyS, () => {
            void send({ type: "save", id: surface!.id }).catch(fail);
          });
          view.onDidFocusEditorText(() => {
            lastFocusedView = view;
            const position = view.getPosition();
            if (position) void send({ type: "focus", id: surface!.id,
              line: position.lineNumber - 1, column: position.column - 1 }).catch(fail);
          });
          view.onDidChangeCursorPosition(event => {
            if (view.hasTextFocus()) void send({ type: "cursor", id: surface!.id,
              line: event.position.lineNumber - 1, column: event.position.column - 1 }).catch(fail);
          });
        }
        if (surface.editor.getModel() !== entry.model) {
          const state = surface.editor.saveViewState();
          if (state) surface.states.set(surface.id, state);
          surface.id = payload.id;
          surface.editor.setModel(entry.model);
          const retained = surface.states.get(payload.id);
          if (retained) surface.editor.restoreViewState(retained);
        }
        applyReadOnly(entry);
        if (payload.focus) surface.editor.focus();
      });
      return activation;
    },
    detachSurface(surfaceID: string) {
      surfaceOperations.set(surfaceID, (surfaceOperations.get(surfaceID) ?? 0) + 1);
      const surface = surfaces.get(surfaceID);
      if (!surface) return;
      surface.editor.dispose();
      surfaces.delete(surfaceID);
    },
    async holdForClose(id: string, token: string, payload?: any) {
      const operation = closingOperations.get(token) ?? { cancelled: false };
      closingOperations.set(token, operation);
      await activation;
      if (operation.cancelled) throw new Error("Close preparation was cancelled");
      const entry = entries.get(id) ?? (payload ? await prepareEntry(payload) : undefined);
      if (operation.cancelled || !entry || failed) {
        closingOperations.delete(token);
        throw new Error("Editor is unavailable");
      }
      operation.entry = entry;
      const inputPasses = await drainInput(entry);
      if (operation.cancelled) throw new Error("Close preparation was cancelled");
      entry.closingHolds = (entry.closingHolds ?? 0) + 1;
      applyReadOnly(entry);
      await entry.chain;
      return { revision: entry.revision, text: entry.source.value, modelVersion: entry.model.getVersionId(),
        pendingEdits: entry.pendingEdits, inputPasses };
    },
    releaseClose(token: string) {
      const operation = closingOperations.get(token);
      if (!operation) return;
      operation.cancelled = true;
      closingOperations.delete(token);
      if (operation.entry) {
        operation.entry.closingHolds = Math.max(0, (operation.entry.closingHolds ?? 0) - 1);
        applyReadOnly(operation.entry);
      }
    },
    async freeze(id: string, operationID?: string) {
      await activation;
      const entry = entries.get(id);
      if (!entry || failed) throw new Error("Editor is unavailable");
      const token = operationID ?? `editor-${++freezeSequence}`;
      if (entry.frozen && entry.freezeOperation !== token) throw new Error("Editor is already synchronizing");
      const inputPasses = await drainInput(entry);
      entry.frozen = true;
      entry.freezeOperation = token;
      applyReadOnly(entry);
      // Capture a revision cut synchronously, then wait only for the edits that
      // produced that cut to cross the bridge. Input arriving while native save
      // work continues belongs to a newer dirty revision and remains editable.
      const revision = entry.revision, text = entry.source.value;
      const modelVersion = entry.model.getVersionId(), barrier = entry.chain;
      await barrier;
      return { revision, text, operationID: token, modelVersion, barrierDrained: true,
        currentRevision: entry.revision, pendingEdits: entry.pendingEdits, inputPasses };
    },
    async freezeAll() {
      await activation;
      if (failed) throw new Error("Editor is unavailable");
      await Promise.all([...entries.values()].map(drainInput));
      for (const view of allEditors()) view.updateOptions({ readOnly: true });
      for (const entry of entries.values()) entry.frozen = true;
      await Promise.all([...entries.values()].map(entry => entry.chain));
      return Object.fromEntries([...entries].map(([id, entry]) => [id, { revision: entry.revision, text: entry.source.value }]));
    },
    unlock(id: string, operationID?: string) {
      const entry = entries.get(id);
      if (!entry) return;
      if (operationID !== undefined && entry.freezeOperation !== operationID) return;
      entry.frozen = false;
      entry.freezeOperation = undefined;
      applyReadOnly(entry);
    },
    async replace(payload: any) {
      await activation;
      const entry = entries.get(payload.id);
      if (!entry) return;
      await entry.chain;
      if (entry.revision !== payload.previousRevision) throw new Error("External edit raced with typing");
      updating = true;
      try {
        entry.model.pushEditOperations([], [{ range: entry.model.getFullModelRange(), text: toMonacoModelValue(payload.text) }], () => null);
        entry.source.replace(payload.text, entry.model.getAlternativeVersionId());
        entry.revision = payload.revision;
      } finally { updating = false; }
    },
    configure(payload: any) {
      monaco.editor.setTheme(payload.dark ? "lithe-dark" : "lithe-light");
      Object.assign(displayOptions, { fontFamily: payload.fontFamily, fontSize: payload.fontSize, wordWrap: payload.wrap ? "on" : "off" });
      for (const view of allEditors()) view.updateOptions(displayOptions);
    },
    async debugState(id: string, state: { breakpoints: { line: number; enabled: boolean; verified: boolean; logpoint: boolean; conditional?: boolean; message?: string }[]; muted: boolean; paused?: boolean; canRunToCursor?: boolean; executionLine?: number; revision?: number; variables?: { name: string; value: string }[] }) {
      await activation;
      const entry = entries.get(id);
      if (!entry) return;
      entry.debugPaused = state.paused === true;
      entry.debugGeneration = (entry.debugGeneration ?? 0) + 1;
      for (const view of allEditors()) if (view.getModel() === entry.model)
        debugRunContexts.get(view)?.set(state.canRunToCursor === true);
      const decorations: monaco.editor.IModelDeltaDecoration[] = state.breakpoints
        .filter(point => point.line >= 1 && point.line <= entry.model.getLineCount()).map(point => ({
          range: new monaco.Range(point.line, 1, point.line, 1),
          options: { glyphMarginClassName: `codicon codicon-${point.logpoint ? "debug-breakpoint-log" : point.conditional ? "debug-breakpoint-conditional" : "debug-breakpoint"}${!point.enabled || state.muted ? "-disabled" : !point.verified ? "-unverified" : ""} lithe-breakpoint`,
            glyphMarginHoverMessage: point.message ? { value: point.message, isTrusted: false } : undefined,
            stickiness: monaco.editor.TrackedRangeStickiness.NeverGrowsWhenTypingAtEdges },
        }));
      if (state.executionLine && state.executionLine <= entry.model.getLineCount() && state.executionLine >= 1) {
        decorations.push({ range: new monaco.Range(state.executionLine, 1, state.executionLine, 1),
          options: { isWholeLine: true, className: "lithe-execution-line",
            glyphMarginClassName: "codicon codicon-debug-stackframe lithe-execution-marker",
            glyphMargin: { position: monaco.editor.GlyphMarginLane.Right },
            stickiness: monaco.editor.TrackedRangeStickiness.NeverGrowsWhenTypingAtEdges } });
        const variables = new Map((state.revision === undefined || state.revision === entry.revision ? state.variables ?? [] : [])
          .map(value => [value.name, value.value]));
        const names = new Set(entry.model.getLineContent(state.executionLine).match(/[$_\p{L}][$_\p{L}\p{N}]*/gu) ?? []);
        const values = [...names].filter(name => variables.has(name)).slice(0, 4).map(name => {
          const value = [...variables.get(name)!.replace(/[\r\n]/g, " ")];
          return `${name} = ${value.length > 80 ? value.slice(0, 79).join("") + "…" : value.join("")}`;
        });
        if (values.length) {
          const column = entry.model.getLineMaxColumn(state.executionLine);
          decorations.push({ range: new monaco.Range(state.executionLine, column, state.executionLine, column),
            options: { after: { content: `  ${values.join(", ")}`, inlineClassName: "lithe-debug-value" },
              stickiness: monaco.editor.TrackedRangeStickiness.NeverGrowsWhenTypingAtEdges } });
        }
      }
      entry.debugDecorations = entry.model.deltaDecorations(entry.debugDecorations ?? [], decorations);
    },
    async markers(id: string, markers: monaco.editor.IMarkerData[]) {
      await activation;
      const entry = entries.get(id);
      if (entry) monaco.editor.setModelMarkers(entry.model, "lithe", markers);
    },
    async retain(ids: string[]) {
      await activation;
      for (const [id, entry] of entries) {
        if (ids.includes(id)) continue;
        await entry.chain;
        if (active === id) { editor.setModel(null); active = undefined; }
        for (const surface of surfaces.values()) {
          if (surface.id === id) surface.editor.setModel(null);
          surface.states.delete(id);
        }
        entry.release(); entries.delete(id);
      }
    },
    async nativeFind(input: NativeFindInput) {
      const generation = input.command ? nativeFindGeneration : ++nativeFindGeneration;
      const requestedEntry = entries.get(input.id);
      const requestedVersion = requestedEntry?.model.getVersionId();
      // Invalidate the previous callback immediately, before activation can yield.
      await activation;
      if (generation !== nativeFindGeneration) return;
      const entry = entries.get(input.id);
      if (input.command && (!entry || entry !== requestedEntry || entry.model.getVersionId() !== requestedVersion)) return;
      if (!input.visible || !entry || suspendedViews) { dismissNativeFind(); return; }
      const matching = allEditors().filter(view => view.getModel() === entry.model);
      const target = matching.find(view => view.hasTextFocus()) ??
        (lastFocusedView && matching.includes(lastFocusedView) ? lastFocusedView : undefined) ??
        (nativeFind && matching.includes(nativeFind.view) ? nativeFind.view : matching[0]);
      if (!target) { dismissNativeFind(); return; }
      nativeFindFocusTarget = { id: input.id, view: target, model: entry.model };
      if (nativeFind?.view !== target || nativeFind.model !== entry.model) {
        dismissNativeFind();
        const widget = captureFind(target);
        if (widget?.isRevealed) findController(target)?.getState().change({ ...widget, isRevealed: false }, false);
        const report = (index: number, count: number) => {
          const current = nativeFind;
          if (!current || current.generation !== nativeFindGeneration || current.view !== target || current.model !== target.getModel()) return;
          void languageRequest({ type: "findState", id: current.input.id, token: current.input.token, index, count });
        };
        nativeFind = { view: target, model: entry.model, generation, input, search: mountNativeFind(target, report),
          changed: target.onDidChangeModel(dismissNativeFind), disposed: target.onDidDispose(dismissNativeFind) };
      }
      nativeFind.input = input;
      nativeFind.generation = generation;
      return nativeFind.search.update(input, !entry.readonly && !entry.frozen && !entry.closingHolds && !failed);
    },
    async dismissNativeFind(id: string) {
      await activation;
      ++nativeFindGeneration;
      const target = nativeFindFocusTarget;
      dismissNativeFind();
      nativeFindFocusTarget = undefined;
      const entry = entries.get(id);
      if (!target || target.id !== id || !entry || target.model !== entry.model ||
          target.view.getModel() !== entry.model || !allEditors().includes(target.view) || suspendedViews) return false;
      target.view.focus();
      lastFocusedView = target.view;
      return target.view.hasTextFocus();
    },
    async find(payload?: { id?: string; surface?: string; query?: string; matchCase?: boolean; wholeWord?: boolean; regex?: boolean }) {
      await activation;
      const requested = payload?.surface ? surfaces.get(payload.surface)?.editor : undefined;
      const model = payload?.id ? entries.get(payload.id)?.model : undefined;
      // An explicit missing surface/document must not silently search a different file.
      if ((payload?.surface && !requested) || (payload?.id && !model)) return;
      const candidates = requested ? [requested] : allEditors();
      const matching = model ? candidates.filter(view => view.getModel() === model) : candidates;
      const target = matching.find(view => view.hasTextFocus()) ?? matching[0];
      if (!target) return;
      if (payload?.query === undefined) {
        await runEditorCommand(target, { type: "find", replace: false }, false);
      } else {
        const findOptions = target.getOption(monaco.editor.EditorOption.find);
        // Monaco seeds the first search from the caret even when arguments include
        // a query. Explicit preview queries must win, including an empty query.
        // This pinned Monaco option exists at runtime but is omitted from its public declaration.
        const previewFind: monaco.editor.IEditorFindOptions & { globalFindClipboard: boolean } =
          { seedSearchStringFromSelection: "never", globalFindClipboard: false };
        target.updateOptions({ find: previewFind });
        try {
          await target.getAction("editor.actions.findWithArgs")?.run({
            searchString: payload.query,
            isCaseSensitive: payload.matchCase ?? false,
            matchWholeWord: payload.wholeWord ?? false,
            isRegex: payload.regex ?? false,
          });
        } finally { target.updateOptions({ find: findOptions }); }
      }
    },
    async navigate(payload: any) {
      await activation;
      const model = entries.get(payload.id)?.model;
      const matches = allEditors().filter(view => view.getModel() === model);
      const target = matches.find(view => view.hasTextFocus()) ?? matches[0];
      if (!target) return;
      target.setPosition({ lineNumber: payload.line + 1, column: payload.column + 1 });
      target.revealLineInCenter(payload.line + 1);
      target.focus();
    },
  };

  async function main() {
    const source = await fetch("worker.js");
    if (!source.ok) throw new Error("Monaco worker resource is unavailable");
    const url = URL.createObjectURL(new Blob([await source.text()], { type: "text/javascript" }));
    window.MonacoEnvironment = { getWorker() { const worker = new Worker(url); workers.push(worker); return worker; } };
    await ensureMonacoLanguageTokenizer("java");
    installThemes(host.palette);
    displayOptions = {
      model: null, automaticLayout: true, minimap: { enabled: false }, theme: "lithe-dark", fontSize: 13,
      glyphMargin: true, scrollBeyondLastLine: false, fixedOverflowWidgets: true, "semanticHighlighting.enabled": true,
    };
    editor = monaco.editor.create(document.querySelector("#editor") as HTMLElement, displayOptions);
    attachDebugInteractions(editor);
    editor.onDidLayoutChange(preserveMarkdownScroll);
    editor.onDidScrollChange(event => {
      if (event.scrollHeightChanged) { preserveMarkdownScroll(); return; }
      if (!event.scrollTopChanged || applyingMarkdownScroll || !active || active !== markdownScrollID || markdownScrollTimer !== undefined) return;
      const id = active, entry = entries.get(id);
      // Only the Markdown split opts in. Coalesce wheel/trackpad bursts instead
      // of publishing every layout event into the native workbench view graph.
      markdownScrollTimer = setTimeout(() => {
        markdownScrollTimer = undefined;
        if (!entry || entries.get(id) !== entry || active !== id || markdownScrollID !== id || editor.getModel() !== entry.model) return;
        const extent = Math.max(0, editor.getScrollHeight() - editor.getLayoutInfo().height);
        const ratio = extent ? Math.min(1, Math.max(0, editor.getScrollTop() / extent)) : 0;
        if (lastMarkdownRatio !== undefined && Math.abs(ratio - lastMarkdownRatio) <= 0.0005) return;
        lastMarkdownRatio = ratio;
        void send({ type: "markdownScroll", id, ratio }).catch(console.error);
      }, 33);
    });
    const debugStyle = document.createElement("style");
    const navigationIconStyles = Object.entries(host.javaNavigationIcons ?? {}).map(([kind, svg]) =>
      `.monaco-editor .lithe-java-navigation-${kind}:${kind.startsWith("up-") ? "before" : "after"}{content:"";background-image:url("data:image/svg+xml,${encodeURIComponent(svg)}")}`).join("\n");
    debugStyle.textContent = `.monaco-editor .lithe-java-navigation{cursor:pointer;font-family:monospace;font-size:12px;display:flex!important;align-items:center;justify-content:center}
      .monaco-editor .lithe-java-navigation:before,.monaco-editor .lithe-java-navigation:after{width:12px;height:12px;background-size:contain;background-repeat:no-repeat;background-position:center;line-height:12px}
      .monaco-editor .lithe-java-navigation-up:before,.monaco-editor .lithe-java-navigation-both:before{content:'↑'}
      .monaco-editor .lithe-java-navigation-down:after,.monaco-editor .lithe-java-navigation-both:after{content:'↓'}
      .monaco-editor .lithe-java-navigation-both:before,.monaco-editor .lithe-java-navigation-both:after{width:50%;max-width:12px}
      ${navigationIconStyles}
      .monaco-editor .lithe-blame{display:inline-block;max-width:calc(100% - 5ch);float:left;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;cursor:pointer;text-align:left}
      .monaco-editor .lithe-blame-line{display:inline-block;min-width:4ch;text-align:right}
      .monaco-editor .lithe-git-marker{width:3px!important;margin-left:2px;cursor:pointer}
      .monaco-editor .lithe-git-added{background:var(--vscode-editorGutter-addedBackground,#2ea043)}
      .monaco-editor .lithe-git-modified{background:var(--vscode-editorGutter-modifiedBackground,#0078d4)}
      .monaco-editor .lithe-git-deleted{background:var(--vscode-editorGutter-deletedBackground,#f85149);height:3px!important}
      .monaco-editor .lithe-breakpoint{color:var(--vscode-debugIcon-breakpointForeground,#e51400)}
      .monaco-editor .lithe-execution-marker{color:var(--vscode-debugIcon-stackFrameForeground,#ffcc00)}
      .monaco-editor .lithe-execution-line{background:var(--vscode-editor-stackFrameHighlightBackground,#ffff0033)}
      .monaco-editor .lithe-debug-value{color:var(--vscode-editor-inlineValuesForeground,#888);background:var(--vscode-editor-inlineValuesBackground,transparent);font-style:italic}`;
    document.head.append(debugStyle);
    textmate = await installJavaTextMate();
    monaco.languages.registerDocumentSemanticTokensProvider("java", {
      getLegend: () => MONACO_SEMANTIC_TOKEN_LEGEND,
      onDidChange: semanticChanges.event,
      releaseDocumentSemanticTokens() {},
      async provideDocumentSemanticTokens(model, _lastResultID, token) {
        const pair = [...entries].find(([, entry]) => entry.model === model);
        if (!pair) return null;
        const [id, entry] = pair;
        const current = documentCheckpoint(id, entry);
        await entry.chain;
        if (!current() || token.isCancellationRequested) return null;
        const revision = entry.revision, version = model.getVersionId();
        const generation = semanticGeneration;
        const key = `${revision}:${version}:${generation}`;
        let cached = semanticCache.get(entry);
        if (cached?.key !== key) {
          cached = { key, promise: languageRequest({ type: "semantic", id, revision }) };
          semanticCache.set(entry, cached);
        }
        const reply = await cached.promise;
        if (!current() || token.isCancellationRequested || model.isDisposed() || entry.revision !== revision ||
            model.getVersionId() !== version || generation !== semanticGeneration || reply.cancelled) {
          if (semanticCache.get(entry) === cached) semanticCache.delete(entry);
          return null;
        }
        return { data: encodeMonacoSemanticTokens(reply, model) };
      },
    });
    editor.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyS, () => {
      if (active) void send({ type: "save", id: active }).catch(fail);
    });
    editor.onDidFocusEditorText(() => {
      lastFocusedView = editor;
      const position = editor.getPosition();
      if (active && position) void send({ type: "focus", id: active,
        line: position.lineNumber - 1, column: position.column - 1 }).catch(fail);
    });
    editor.onDidChangeCursorPosition(event => {
      if (active && editor.hasTextFocus()) void send({ type: "cursor", id: active, line: event.position.lineNumber - 1, column: event.position.column - 1 }).catch(fail);
    });
    const codeVisionCommand = monaco.editor.registerCommand("lithe.codeVision", async (_accessor, context) => {
      const { id, entry, version, revision, hint, action, current } = context;
      if (!current() || entries.get(id) !== entry || entry.model.isDisposed() || entry.model.getVersionId() !== version ||
          entry.revision !== revision || entry.frozen || entry.closingHolds || failed) return;
      await languageRequest({ type: "codeVisionAction", id, revision, hint, action });
    });
    const codeVision: monaco.languages.CodeLensProvider = {
      onDidChange: listener => codeVisionChanges.event(() => listener(codeVision)),
      async provideCodeLenses(model, token) {
        const pair = [...entries].find(([, entry]) => entry.model === model);
        if (!pair) return { lenses: [], dispose() {} };
        const [id, entry] = pair;
        const current = documentCheckpoint(id, entry);
        const version = model.getVersionId();
        await entry.chain;
        if (!current() || token.isCancellationRequested || model.isDisposed() || entries.get(id) !== entry || model.getVersionId() !== version)
          return { lenses: [], dispose() {} };
        const revision = entry.revision;
        const reply = await languageRequest({ type: "codeVision", id, revision });
        if (!current() || reply.cancelled || token.isCancellationRequested || model.isDisposed() || entries.get(id) !== entry ||
            model.getVersionId() !== version || entry.revision !== revision) return { lenses: [], dispose() {} };
        const lenses: monaco.languages.CodeLens[] = [];
        for (const hint of reply.hints ?? []) {
          if (hint.line < 1 || hint.line > model.getLineCount()) continue;
          const range = new monaco.Range(hint.line, 1, hint.line, 1);
          const add = (action: string, title: string) => lenses.push({ range, command: { id: "lithe.codeVision", title,
            arguments: [{ id, entry, version, revision, hint: hint.id, action, current }] } });
          if (hint.usageCount > 0) add("usages", `${hint.usageCount} usage${hint.usageCount === 1 ? "" : "s"}`);
          if (hint.implementationCount > 0) add("implementations", `${hint.implementationCount} implementation${hint.implementationCount === 1 ? "" : "s"}`);
          if (hint.authorName) add("author", hint.authorName);
        }
        return { lenses, dispose() {} };
      },
    };
    const codeVisionProvider = monaco.languages.registerCodeLensProvider("java", codeVision);
    monaco.languages.registerInlayHintsProvider("*", {
      onDidChangeInlayHints: semanticChanges.event,
      async provideInlayHints(model, range, token) {
        const pair = [...entries].find(([, entry]) => entry.model === model);
        if (!pair) return { hints: [], dispose() {} };
        const [id, entry] = pair;
        const current = documentCheckpoint(id, entry);
        await entry.chain;
        if (!current() || token.isCancellationRequested || entries.get(id) !== entry || model.isDisposed()) return { hints: [], dispose() {} };
        const version = model.getVersionId(), revision = entry.revision;
        const reply = await languageRequest({ type: "inlayHints", id, revision,
          line: range.startLineNumber - 1, column: range.startColumn - 1,
          endLine: range.endLineNumber - 1, endColumn: range.endColumn - 1 });
        if (!current() || token.isCancellationRequested || entries.get(id) !== entry || model.isDisposed() ||
            model.getVersionId() !== version || entry.revision !== revision || reply.cancelled) return { hints: [], dispose() {} };
        return { hints: (reply.hints ?? []).filter((hint: any) =>
          monaco.Position.equals(hint.position, model.validatePosition(hint.position)) &&
          (hint.textEdits ?? []).every((edit: any) => monaco.Range.equalsRange(edit.range, model.validateRange(edit.range)))).map((hint: any) => ({
            ...hint, kind: hint.kind === 1 ? monaco.languages.InlayHintKind.Type :
              hint.kind === 2 ? monaco.languages.InlayHintKind.Parameter : undefined,
            tooltip: hint.tooltip ? { value: hint.tooltip, isTrusted: false, supportHtml: false } : undefined,
          })), dispose() {} };
      },
    });
    monaco.languages.registerDocumentFormattingEditProvider("*", {
      async provideDocumentFormattingEdits(model, _options, token) {
        const pair = [...entries].find(([, entry]) => entry.model === model);
        if (!pair || model.isDisposed()) return [];
        const [id, entry] = pair;
        const current = documentCheckpoint(id, entry);
        await entry.chain;
        if (!current() || token.isCancellationRequested || model.isDisposed() || entries.get(id) !== entry) return [];
        const revision = entry.revision, version = model.getVersionId();
        const reply = await languageRequest({ type: "format", id, revision });
        if (!current() || token.isCancellationRequested || model.isDisposed() || entries.get(id) !== entry ||
            model.getVersionId() !== version || entry.revision !== revision || entry.closingHolds || entry.frozen || reply.cancelled) return [];
        return reply.edits ?? [];
      },
    });
    monaco.languages.registerRenameProvider("*", {
      async provideRenameEdits(model, position, newName, token) {
        const pair = [...entries].find(([, entry]) => entry.model === model);
        if (!pair) return { edits: [] };
        const [id, entry] = pair;
        const current = documentCheckpoint(id, entry);
        const unchanged = workspaceCheckpoint();
        await Promise.all([...entries.values()].map(value => value.chain));
        if (!current() || token.isCancellationRequested || entries.get(id) !== entry || model.isDisposed()) return { edits: [] };
        const valid = () => !token.isCancellationRequested && unchanged();
        const reply = await languageRequest({ type: "rename", id, revision: entry.revision,
          line: position.lineNumber - 1, column: position.column - 1, newName });
        if (!valid() || reply.cancelled) return { edits: [], rejectReason: "Rename result is no longer current." };
        try { return await prepareWorkspaceChanges(reply.changes ?? [], valid); }
        catch (error) { return { edits: [], rejectReason: String(error) }; }
      },
    });
    const codeActionRequests = new WeakMap<Entry, object>();
    const executingCodeActions = new WeakSet<Entry>();
    type ActionContext = { id: string; entry: Entry; revision: number; list: string; index: number; valid: () => boolean };
    const codeActionCommand = monaco.editor.registerCommand("lithe.applyCodeAction", async (_accessor, context: ActionContext) => {
      if (!context.valid() || executingCodeActions.has(context.entry)) return;
      executingCodeActions.add(context.entry);
      try {
        const reply = await languageRequest({ type: "resolveCodeAction", id: context.id,
          revision: context.revision, list: context.list, index: context.index });
        if (!context.valid() || reply.cancelled) return;
        const edit = await prepareWorkspaceChanges(reply.changes ?? [], context.valid);
        if (edit.edits.length) await StandaloneServices.get(IBulkEditService).apply(edit);
        // Commands can depend on the new document text. Drain all affected edits
        // before execution and reject new input that arrives during the drain.
        const unchanged = workspaceCheckpoint();
        await Promise.all([...entries.values()].map(entry => entry.chain));
        if (reply.command && unchanged() && entries.get(context.id) === context.entry) {
          await languageRequest({ type: "executeCodeAction", id: context.id,
            revision: context.entry.revision, command: reply.command });
        }
      } finally { executingCodeActions.delete(context.entry); }
    });
    monaco.languages.registerCodeActionProvider("*", {
      async provideCodeActions(model, range, _context, token) {
        const pair = [...entries].find(([, entry]) => entry.model === model);
        if (!pair) return { actions: [], dispose() {} };
        const [id, entry] = pair;
        const current = documentCheckpoint(id, entry);
        const unchanged = workspaceCheckpoint();
        await Promise.all([...entries.values()].map(value => value.chain));
        if (!current() || token.isCancellationRequested || entries.get(id) !== entry || model.isDisposed() || entry.readonly)
          return { actions: [], dispose() {} };
        const request = {};
        codeActionRequests.set(entry, request);
        const revision = entry.revision;
        const valid = () => codeActionRequests.get(entry) === request && unchanged();
        const reply = await languageRequest({ type: "codeActions", id, revision,
          line: range.startLineNumber - 1, column: range.startColumn - 1,
          endLine: range.endLineNumber - 1, endColumn: range.endColumn - 1 });
        if (token.isCancellationRequested || !valid() || reply.cancelled) return { actions: [], dispose() {} };
        return { actions: (reply.actions ?? []).map((action: any) => ({
          title: action.title, kind: action.kind, isPreferred: action.isPreferred,
          command: { id: "lithe.applyCodeAction", title: action.title,
            arguments: [{ id, entry, revision, list: reply.list, index: action.index, valid } satisfies ActionContext] },
        })), dispose() {} };
      },
    });
    monaco.languages.registerHoverProvider("*", {
      async provideHover(model, position, token) {
        const pair = [...entries].find(([, entry]) => entry.model === model);
        const id = pair?.[0]; const entry = pair?.[1];
        if (!id || !entry || entry.model !== model) return null;
        const current = documentCheckpoint(id, entry);
        await entry.chain;
        if (!current() || token.isCancellationRequested || model.isDisposed() || entries.get(id) !== entry) return null;
        const revision = entry.revision, version = model.getVersionId();
        const debugGeneration = entry.debugGeneration;
        const expression = model.getWordAtPosition(position)?.word;
        const [reply, debug] = await Promise.all([
          languageRequest({ type: "hover", id, revision, line: position.lineNumber - 1, column: position.column - 1 }),
          entry.debugPaused && expression && /^[$_\p{L}][$_\p{L}\p{N}]*$/u.test(expression)
            ? languageRequest({ type: "debugHover", id, revision, expression }) : Promise.resolve(undefined),
        ]);
        if (!current() || token.isCancellationRequested || entries.get(id) !== entry || model.isDisposed() || entry.revision !== revision || model.getVersionId() !== version) return null;
        const contents: monaco.IMarkdownString[] = [];
        if (debug?.contents && !debug.cancelled && entry.debugPaused && entry.debugGeneration === debugGeneration)
          contents.push({ value: String(debug.contents).replace(/[\\`*_{}[\]()<>#+.!|~-]/g, "\\$&"), isTrusted: false, supportHtml: false });
        if (reply.contents && !reply.cancelled) contents.push({ value: reply.contents, isTrusted: false, supportHtml: false });
        return contents.length ? { contents } : null;
      },
    });
    const completionRequests = new WeakMap<Entry, object>();
    const completionContexts = new WeakMap<monaco.languages.CompletionItem, {
      id: string; entry: Entry; version: number; revision: number; list: string; index: number; request: object; current: () => boolean;
    }>();
    monaco.languages.registerCompletionItemProvider("*", {
      triggerCharacters: ["."],
      async provideCompletionItems(model, position, _context, token) {
        const pair = [...entries].find(([, entry]) => entry.model === model);
        const id = pair?.[0]; const entry = pair?.[1];
        if (!id || !entry || entry.model !== model) return { suggestions: [] };
        const current = documentCheckpoint(id, entry);
        await entry.chain;
        if (!current() || token.isCancellationRequested || model.isDisposed() || entries.get(id) !== entry) return null;
        const revision = entry.revision, version = model.getVersionId();
        const request = {};
        completionRequests.set(entry, request);
        const reply = await languageRequest({ type: "completion", id, revision, line: position.lineNumber - 1, column: position.column - 1 });
        if (!current() || token.isCancellationRequested || entries.get(id) !== entry || model.isDisposed() || entry.revision !== revision || model.getVersionId() !== version || completionRequests.get(entry) !== request || reply.cancelled) return { suggestions: [] };
        const word = model.getWordUntilPosition(position);
        return { suggestions: (reply.items ?? []).map((item: any) => {
          const suggestion = { ...item, kind: mapCompletionKind(item.kind),
            insertTextRules: item.insertTextFormat === 2 ? monaco.languages.CompletionItemInsertTextRule.InsertAsSnippet : undefined,
            range: item.range ?? new monaco.Range(position.lineNumber, word.startColumn, position.lineNumber, word.endColumn) };
          if (item.completionList) completionContexts.set(suggestion,
            { id, entry, version, revision, list: item.completionList, index: item.completionIndex, request, current });
          return suggestion;
        }) };
      },
      async resolveCompletionItem(item, token) {
        const context = completionContexts.get(item);
        if (!context) return item;
        const { id, entry, version, revision } = context;
        const valid = () => context.current() && !token.isCancellationRequested && entries.get(id) === entry && !entry.model.isDisposed()
          && entry.model.getVersionId() === version && entry.revision === revision
          && !entry.closingHolds && !entry.frozen && completionRequests.get(entry) === context.request;
        if (!valid()) return item;
        const reply = await languageRequest({ type: "resolveCompletion", id, revision,
          completionList: context.list, completionIndex: context.index });
        if (!valid() || reply.cancelled || !reply.item) return item;
        return { ...item, ...reply.item, range: reply.item.range ?? item.range,
          kind: mapCompletionKind(reply.item.kind),
          insertTextRules: reply.item.insertTextFormat === 2 ? monaco.languages.CompletionItemInsertTextRule.InsertAsSnippet : undefined };
      },
    });
    addEventListener("pagehide", () => {
      clearTimeout(markdownScrollTimer);
      codeActionCommand.dispose();
      codeVisionCommand.dispose(); codeVisionProvider.dispose(); codeVisionChanges.dispose();
      debugStyle.remove();
      for (const cancel of openingMeasurements) cancel();
      ++nativeFindGeneration; dismissNativeFind();
      review?.dispose(); semanticChanges.dispose(); for (const view of allEditors()) view.dispose(); surfaces.clear(); entries.forEach(entry => entry.release()); textmate?.dispose(); workers.forEach(worker => worker.terminate()); URL.revokeObjectURL(url);
    });
    await send({ type: "ready" });
  }
  const ready = main().catch(error => { fail(error); throw error; });
  return { api, ready };
}
