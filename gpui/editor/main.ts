// GPUI Monaco host.
//
// This page implements the JS half of gpui/editor/PROTOCOL.md: it owns Monaco,
// forwards edits/saves/cursor movement through window.ipc, and exposes the
// asynchronous window.lithe API that the Rust side calls with evaluate_script.
// It deliberately knows nothing about the filesystem, LSP or native dialogs.

import * as monaco from "monaco-editor/esm/vs/editor/editor.api.js";
import "monaco-editor/esm/vs/editor/editor.all.js";
import "monaco-editor/esm/vs/basic-languages/java/java.contribution.js";
import "monaco-editor/esm/vs/basic-languages/markdown/markdown.contribution.js";
import "monaco-editor/esm/vs/basic-languages/xml/xml.contribution.js";
import "monaco-editor/esm/vs/basic-languages/css/css.contribution.js";
import "monaco-editor/esm/vs/basic-languages/html/html.contribution.js";
import {
  createBridge,
  errorMessage,
  type LitheApi,
  type LitheConfigurePayload,
  type LitheIpc,
  type LitheOpenPayload,
} from "./protocol";

declare global {
  interface Window {
    lithe: LitheApi;
    ipc?: LitheIpc;
  }
}

// Build output is worker.js next to index.html; never load Monaco workers from
// a CDN or an external origin.
(self as unknown as { MonacoEnvironment: { getWorker(workerId: string, label: string): Worker } })
  .MonacoEnvironment = {
  getWorker() {
    return new Worker(new URL("worker.js", document.baseURI), { name: "lithe-editor-worker" });
  },
};

interface Appearance {
  dark: boolean;
  background: string;
  foreground: string;
  fontFamily: string;
  fontSize: number;
  wrap: boolean;
  minimap: boolean;
  lineNumbers: boolean;
  scrollBeyondLastLine: boolean;
  renderWhitespace: boolean;
  fontLigatures: boolean;
  codeLens: boolean;
  tabSize: number;
}

const DEFAULT_FONT_FAMILY = '"JetBrains Mono", "SFMono-Regular", Menlo, Consolas, monospace';

const appearance: Appearance = {
  dark: true,
  background: "#1e1e1e",
  foreground: "#d4d4d4",
  fontFamily: DEFAULT_FONT_FAMILY,
  fontSize: 13,
  wrap: false,
  minimap: false,
  lineNumbers: true,
  scrollBeyondLastLine: false,
  renderWhitespace: false,
  fontLigatures: false,
  codeLens: false,
  tabSize: 4,
};

interface Entry {
  /** Document id owned by Rust; every lightweight LSP request must echo it. */
  id: string;
  /** Absolute path Rust opened this document with. */
  filename: string;
  model: monaco.editor.ITextModel;
  viewState: monaco.editor.ICodeEditorViewState | null;
  readOnly: boolean;
  revision: number;
  dirtyTimer: number | undefined;
  changeListener: monaco.IDisposable;
  lastSaved: boolean;
  /** 本地脏状态：Save All 只提交脏模型，不能只看 Rust 侧的当前文档标记。 */
  dirty: boolean;
}

const bridge = createBridge();
const entries = new Map<string, Entry>();
const entryByModel = new WeakMap<monaco.editor.ITextModel, Entry>();
const pendingOpens: LitheOpenPayload[] = [];
let editor: monaco.editor.IStandaloneCodeEditor | null = null;
let activeId: string | null = null;
/**
 * 分屏副窗格的只读开关（宿主通过 setReadonly 设置）。
 *
 * 单独记一份而不是只写进 Monaco：applyConfigure 每次重设整组选项，文档切换
 * 也会按 entry.readOnly 重设，必须把这里的值一起带上，否则只读会被覆盖掉。
 */
let readOnly = false;

const LANGUAGE_BY_EXTENSION: Record<string, string> = {
  java: "java",
  md: "markdown",
  markdown: "markdown",
  mdown: "markdown",
  mkd: "markdown",
  xml: "xml",
  xsd: "xml",
  xsl: "xml",
  xslt: "xml",
  svg: "xml",
  plist: "xml",
  css: "css",
  html: "html",
  htm: "html",
};

const SUPPORTED_LANGUAGES = new Set(["java", "markdown", "xml", "css", "html", "plaintext"]);

function extensionOf(filename: string): string {
  const base = filename.replace(/\\/g, "/").split("/").pop() ?? "";
  const dot = base.lastIndexOf(".");
  return dot > 0 ? base.slice(dot + 1).toLowerCase() : "";
}

function resolveLanguage(language: string | undefined, filename: string): string {
  if (language === "md") return "markdown";
  if (language && SUPPORTED_LANGUAGES.has(language)) return language;
  return LANGUAGE_BY_EXTENSION[extensionOf(filename)] ?? "plaintext";
}

function normalizeOpen(payload: LitheOpenPayload): LitheOpenPayload | undefined {
  if (!payload || typeof payload !== "object") return undefined;
  const id = String(payload.id ?? "");
  if (!id) return undefined;
  return {
    id,
    filename: String(payload.filename ?? ""),
    language: typeof payload.language === "string" && payload.language ? payload.language : undefined,
    text: typeof payload.text === "string" ? payload.text : String(payload.text ?? ""),
    readonly: typeof payload.readonly === "boolean" ? payload.readonly : undefined,
  };
}

function reportFailure(error: unknown): void {
  bridge.notify("failure", { message: errorMessage(error) });
}

function scheduleDirty(id: string, entry: Entry): void {
  // 内容一变就标记本地脏；Rust 的 `dirty` 是防抖后的通知，不能当作唯一真相，
  // 否则 Save All 会漏掉刚改完、通知还在路上的模型。
  entry.dirty = true;
  if (entry.dirtyTimer !== undefined) window.clearTimeout(entry.dirtyTimer);
  entry.dirtyTimer = window.setTimeout(() => {
    entry.dirtyTimer = undefined;
    bridge.notify("dirty", { id, dirty: true });
  }, 150);
}

function handleContentChange(id: string, entry: Entry): void {
  // Every change carries the revision the host last confirmed. Rust replies
  // asynchronously with the next revision, so replies may arrive out of order;
  // never assume that the request has been applied when this returns.
  void bridge
    .request("edit", { id, baseRevision: entry.revision })
    .then((reply) => {
      const revision = (reply as { revision?: unknown } | null | undefined)?.revision;
      if (typeof revision === "number" && Number.isFinite(revision)) entry.revision = revision;
    })
    .catch(reportFailure);
  scheduleDirty(id, entry);
}

/**
 * Save one model through the regular `save` request. Both Ctrl/Cmd+S and Save All
 * go through here so the debounce flush only exists once.
 */
function saveEntry(id: string): void {
  const entry = entries.get(id);
  if (!entry) return;

  flushDirty(id, entry);

  void bridge
    .request("save", { id, text: entry.model.getValue() })
    .then((reply) => {
      const result = reply as { saved?: boolean; error?: string } | null | undefined;
      if (!result || result.saved !== true) {
        reportFailure(new Error(result?.error ?? "Save failed"));
        return;
      }
      // Rust 成功后还会回发 setSaved(id, true)；这里先本地清脏，保证紧接着的
      // Save All 不会重复提交同一个模型。
      entry.dirty = false;
    })
    .catch(reportFailure);
}

/**
 * 提交并清除待发的 dirty 防抖。
 *
 * 保存前必须先做：否则一个迟到的 "dirty: true" 会在 Rust 处理完保存、清掉
 * 脏标记之后才到达，把刚保存的文档重新标脏。
 */
function flushDirty(id: string, entry: Entry): void {
  if (entry.dirtyTimer === undefined) return;
  window.clearTimeout(entry.dirtyTimer);
  entry.dirtyTimer = undefined;
  bridge.notify("dirty", { id, dirty: true });
}

function saveActive(): void {
  if (!activeId) return;
  saveEntry(activeId);
}

function saveAll(): void {
  // 只提交本地脏模型：Rust 的 dirty 只跟踪当前文档，未保存的后台标签不在其中。
  for (const [id, entry] of entries) {
    if (entry.dirty) saveEntry(id);
  }
}

/**
 * Save As：把活动模型写到宿主选定的路径。
 *
 * 路径来自 Rust 侧的原生保存对话框，前端不碰文件系统，只把当前文本发过去；
 * 写盘和标签迁移都由宿主负责，成功后 Rust 会发 `SavedAs` 事件。
 */
function saveAs(path: string): void {
  const id = activeId;
  if (!id) return;
  const entry = entries.get(id);
  if (!entry) return;

  flushDirty(id, entry);

  void bridge
    .request("saveAs", { id, text: entry.model.getValue(), path })
    .then((reply) => {
      const result = reply as { saved?: boolean; error?: string } | null | undefined;
      if (!result || result.saved !== true) {
        reportFailure(new Error(result?.error ?? "Save failed"));
        return;
      }
      // 新路径的标签由工作台在 `SavedAs` 事件里打开，这里只负责清本地脏标记，
      // 避免紧接着的 Save All 再把旧模型提交一遍。
      entry.dirty = false;
    })
    .catch(reportFailure);
}

/**
 * 切换只读模式（Split Editor 副窗格用）。
 *
 * 只切 Monaco 的编辑能力，不碰保存/命令等既有路径；开关单独记在 readOnly 上，
 * 由 applyConfigure 和 activate 一并重设，避免外观或标签切换把只读覆盖掉。
 */
function setReadonly(readonly: boolean): void {
  readOnly = readonly === true;
  editor?.updateOptions({ readOnly });
}

/**
 * 定位到指定行（1-based），供搜索结果、诊断等入口跳转。
 *
 * 行号夹到文档范围内：Core 的行号来自磁盘快照，前端可能已经改过内容，越界时
 * 定位到最后一行比直接抛错更符合预期。
 */
function revealLine(line: number): void {
  if (!editor) return;
  const model = editor.getModel();
  if (!model) return;
  const lastLine = Math.max(1, model.getLineCount());
  const target = Math.min(Math.max(1, Math.floor(Number(line) || 1)), lastLine);
  editor.revealLineInCenter(target);
  editor.setPosition({ lineNumber: target, column: 1 });
  editor.focus();
}

function activate(id: string, readonly?: boolean): void {
  if (!editor) return;
  const entry = entries.get(id);
  if (!entry) return;

  if (typeof readonly === "boolean") entry.readOnly = readonly;

  // Re-opening the active tab must not rewind the cursor to a stale view state.
  if (activeId === id && editor.getModel() === entry.model) {
    editor.updateOptions({ readOnly: entry.readOnly || readOnly });
    editor.focus();
    return;
  }

  // Preserve scroll/cursor of the tab we are leaving.
  if (activeId) {
    const previous = entries.get(activeId);
    if (previous && editor.getModel() === previous.model) {
      previous.viewState = editor.saveViewState();
    }
  }

  activeId = id;
  editor.setModel(entry.model);
  editor.updateOptions({ readOnly: entry.readOnly || readOnly });
  if (entry.viewState) editor.restoreViewState(entry.viewState);
  editor.focus();
}

function openFile(raw: LitheOpenPayload): void {
  const payload = normalizeOpen(raw);
  if (!payload || !editor) return;

  const existing = entries.get(payload.id);
  if (existing) {
    // Same model id means an existing tab. Reopening must never overwrite the
    // buffer with the text Rust sent, otherwise unsaved edits are lost.
    activate(payload.id, payload.readonly);
    return;
  }

  const model = monaco.editor.createModel(
    payload.text,
    resolveLanguage(payload.language, payload.filename),
    monaco.Uri.parse(`inmemory://lithe/${encodeURIComponent(payload.id)}`),
  );
  const entry: Entry = {
    id: payload.id,
    filename: payload.filename,
    model,
    viewState: null,
    readOnly: payload.readonly === true,
    revision: 0,
    dirtyTimer: undefined,
    changeListener: model.onDidChangeContent(() => handleContentChange(payload.id, entry)),
    lastSaved: false,
    dirty: false,
  };
  entries.set(payload.id, entry);
  entryByModel.set(model, entry);
  activate(payload.id);
}

function closeFile(id: string): void {
  const entry = entries.get(id);
  if (!entry) return;

  if (entry.dirtyTimer !== undefined) window.clearTimeout(entry.dirtyTimer);
  entry.changeListener.dispose();

  if (activeId === id) {
    entry.viewState = editor?.saveViewState() ?? entry.viewState;
    // Clear the id first so the cursor event fired by setModel(null) is ignored.
    activeId = null;
    editor?.setModel(null);
  }

  entries.delete(id);
  entryByModel.delete(entry.model);
  entry.model.dispose();
}

function clearEditor(): void {
  if (!editor) return;
  if (activeId) {
    const entry = entries.get(activeId);
    if (entry && editor.getModel() === entry.model) entry.viewState = editor.saveViewState();
  }
  activeId = null;
  editor.setModel(null);
}

// --- Diagnostics -------------------------------------------------------------
//
// Monaco 的 markers 是宿主的 Problems 数据源。模型是 `inmemory://` URI，绝对
// 路径只存在于 Entry.filename，所以收集时一律遍历 entries：不在 entries 里的
// 模型（语言服务自建的、外部打开的）不会上报，避免把非标签文件带进 Problems。

const DIAGNOSTICS_DEBOUNCE_MS = 250;

interface DiagnosticsItem {
  /** 绝对路径；Entry.filename 为空时整条丢弃。 */
  path: string;
  /** Monaco MarkerSeverity 原值：1=Hint, 2=Info, 4=Warning, 8=Error。 */
  severity: number;
  message: string;
  /** 1 起算，与 Monaco 的 startLineNumber/startColumn 一致。 */
  line: number;
  column: number;
  source?: string;
}

let diagnosticsTimer: number | undefined;

function collectDiagnostics(): DiagnosticsItem[] {
  const items: DiagnosticsItem[] = [];
  for (const entry of entries.values()) {
    const path = entry.filename.trim();
    if (!path) continue;
    for (const marker of monaco.editor.getModelMarkers({ resource: entry.model.uri })) {
      const message = marker.message.trim();
      if (!message) continue;
      const item: DiagnosticsItem = {
        path,
        severity: marker.severity,
        message,
        line: Math.max(1, marker.startLineNumber),
        column: Math.max(1, marker.startColumn),
      };
      // 空 source 不发送，Rust 侧保持 None。
      const source = typeof marker.source === "string" ? marker.source.trim() : "";
      if (source) item.source = source;
      items.push(item);
    }
  }
  // 稳定排序：模型创建顺序不同也得到同一份 payload，Rust 才能用 `Vec` 相等
  // 判断“诊断没有变化”并跳过事件。
  items.sort((left, right) => {
    if (left.path !== right.path) return left.path < right.path ? -1 : 1;
    if (left.line !== right.line) return left.line - right.line;
    if (left.column !== right.column) return left.column - right.column;
    if (left.severity !== right.severity) return left.severity - right.severity;
    return left.message < right.message ? -1 : left.message > right.message ? 1 : 0;
  });
  return items;
}

/** 上报全量快照，而不是增量：Rust 用整份列表替换上一份 Problems 数据。 */
function flushDiagnostics(): void {
  diagnosticsTimer = undefined;
  bridge.notify("diagnostics", { items: collectDiagnostics() });
}

/** markers 可能在一次输入里连续变化多次；去抖后只上报最后一轮结果。 */
function scheduleDiagnostics(): void {
  if (diagnosticsTimer !== undefined) window.clearTimeout(diagnosticsTimer);
  diagnosticsTimer = window.setTimeout(flushDiagnostics, DIAGNOSTICS_DEBOUNCE_MS);
}

// --- Lightweight language features -------------------------------------------
//
// The GPUI host does not own an LSP session. These providers call Core's
// same-document fallbacks through the regular request/reply bridge. Every
// failure (10s timeout, missing IPC handler, malformed reply) degrades to an
// empty result: a rejected provider must never put Monaco or the Rust host
// into an error state.

type LightweightMethod = "completion" | "hover" | "definition" | "references";

const LIGHTWEIGHT_LANGUAGE_SELECTOR = [...SUPPORTED_LANGUAGES];
let languageProvidersRegistered = false;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

async function requestLightweight(
  method: LightweightMethod,
  entry: Entry,
  model: monaco.editor.ITextModel,
  position: monaco.Position,
): Promise<unknown> {
  try {
    return await bridge.request("lsp", {
      method,
      id: entry.id,
      filename: entry.filename,
      // The protocol wants the complete document with each request; nothing is
      // cached across keystrokes.
      text: model.getValue(),
      line: position.lineNumber - 1,
      character: position.column - 1,
    });
  } catch (error) {
    console.error(`lithe: lightweight ${method} request failed`, error);
    return null;
  }
}

/** Core reports 0-based lines and UTF-16 columns; Monaco positions are 1-based. */
function toMonacoPosition(value: unknown): monaco.Position | null {
  if (!isRecord(value)) return null;
  const line = value.line;
  const column = value.utf16Column;
  if (typeof line !== "number" || !Number.isInteger(line) || line < 0) return null;
  if (typeof column !== "number" || !Number.isInteger(column) || column < 0) return null;
  return new monaco.Position(line + 1, column + 1);
}

function toMonacoRange(value: unknown): monaco.Range | null {
  if (!isRecord(value)) return null;
  const start = toMonacoPosition(value.start);
  const end = toMonacoPosition(value.end);
  if (!start || !end) return null;
  return new monaco.Range(start.lineNumber, start.column, end.lineNumber, end.column);
}

/** Core's LspTextEditResponse is `{ range, newText }`; accept `text` as well. */
function toCompletionTextEdit(value: unknown): { range: monaco.Range; text: string } | null {
  if (!isRecord(value)) return null;
  const range = toMonacoRange(value.range);
  const text =
    typeof value.newText === "string"
      ? value.newText
      : typeof value.text === "string"
        ? value.text
        : undefined;
  if (!range || text === undefined) return null;
  return { range, text };
}

function toCompletionSuggestion(
  item: unknown,
  position: monaco.Position,
  fallbackRange: monaco.Range,
): monaco.languages.CompletionItem | null {
  if (!isRecord(item) || typeof item.label !== "string" || !item.label) return null;

  const textEdit = toCompletionTextEdit(item.textEdit);
  let range = textEdit?.range ?? fallbackRange;
  // Monaco requires a single-line range containing the cursor. Core returns
  // that shape, but a reply can arrive after the user kept typing; fall back to
  // the word under the cursor rather than discarding the whole list.
  if (!range.isSingleLine() || !range.containsPosition(position)) range = fallbackRange;

  const kind =
    typeof item.kind === "number" && Number.isFinite(item.kind)
      ? (item.kind as monaco.languages.CompletionItemKind)
      : monaco.languages.CompletionItemKind.Text;
  const insertText =
    textEdit?.text ?? (typeof item.insertText === "string" ? item.insertText : item.label);

  return {
    label: item.label,
    kind,
    insertText,
    detail: typeof item.detail === "string" ? item.detail : undefined,
    range,
  };
}

interface NavigationLocation {
  filePath: string;
  range: monaco.Range;
}

function navigationLocations(value: unknown): NavigationLocation[] {
  if (!isRecord(value) || !Array.isArray(value.locations)) return [];
  const locations: NavigationLocation[] = [];
  for (const candidate of value.locations) {
    if (!isRecord(candidate) || typeof candidate.filePath !== "string") continue;
    const range = toMonacoRange(candidate.range);
    if (!range) continue;
    locations.push({ filePath: candidate.filePath, range });
  }
  return locations;
}

function normalizeFilePath(value: string): string {
  return value.trim().replace(/\\/g, "/");
}

/** Rust echoes the path we sent, so separators are the only normalization needed. */
function sameDocumentPath(left: string, right: string): boolean {
  const a = normalizeFilePath(left);
  const b = normalizeFilePath(right);
  if (!a || !b) return false;
  if (a === b) return true;
  const windowsStyle = /^[A-Za-z]:\//.test(a) || a.startsWith("//");
  return windowsStyle && a.toLowerCase() === b.toLowerCase();
}

function hoverValues(hover: Record<string, unknown>): string[] {
  const contents = hover.contents;
  if (typeof contents === "string") return contents ? [contents] : [];
  if (Array.isArray(contents)) {
    const values: string[] = [];
    for (const entry of contents) {
      if (typeof entry === "string" && entry) values.push(entry);
      else if (isRecord(entry) && typeof entry.value === "string" && entry.value) {
        values.push(entry.value);
      }
    }
    return values;
  }
  if (isRecord(contents) && typeof contents.value === "string" && contents.value) {
    return [contents.value];
  }
  return [];
}

/**
 * Core flags plain text hovers with `isMarkdown: false`. Monaco always renders
 * hover contents as markdown, so plain text is wrapped in a code fence; the
 * flag travels with the content for callers that want the raw shape.
 */
function toHoverContent(value: string, isMarkdown: boolean): { value: string; isMarkdown: boolean } {
  return {
    value: isMarkdown ? value : `\`\`\`\n${value}\n\`\`\``,
    isMarkdown,
  };
}

function registerLanguageProviders(): void {
  if (languageProvidersRegistered) return;
  languageProvidersRegistered = true;

  monaco.languages.registerCompletionItemProvider(LIGHTWEIGHT_LANGUAGE_SELECTOR, {
    triggerCharacters: ["."],
    async provideCompletionItems(model, position, _context, token) {
      const entry = entryByModel.get(model);
      if (!entry || token.isCancellationRequested) return { suggestions: [] };

      const word = model.getWordUntilPosition(position);
      const fallbackRange = new monaco.Range(
        position.lineNumber,
        word.startColumn,
        position.lineNumber,
        word.endColumn,
      );

      const response = await requestLightweight("completion", entry, model, position);
      if (token.isCancellationRequested) return { suggestions: [] };

      const items = isRecord(response) && Array.isArray(response.items) ? response.items : [];
      const suggestions: monaco.languages.CompletionItem[] = [];
      for (const item of items) {
        const suggestion = toCompletionSuggestion(item, position, fallbackRange);
        if (suggestion) suggestions.push(suggestion);
      }
      return { suggestions };
    },
  });

  monaco.languages.registerHoverProvider(LIGHTWEIGHT_LANGUAGE_SELECTOR, {
    async provideHover(model, position, token) {
      const entry = entryByModel.get(model);
      if (!entry || token.isCancellationRequested) return null;

      const response = await requestLightweight("hover", entry, model, position);
      if (token.isCancellationRequested) return null;

      const hover = isRecord(response) ? response.hover : undefined;
      if (!isRecord(hover)) return null;
      const values = hoverValues(hover);
      if (values.length === 0) return null;

      const isMarkdown = hover.isMarkdown !== false;
      const contents = values.map((value) => toHoverContent(value, isMarkdown));
      const range = toMonacoRange(hover.range);
      return range ? { contents, range } : { contents };
    },
  });

  monaco.languages.registerDefinitionProvider(LIGHTWEIGHT_LANGUAGE_SELECTOR, {
    async provideDefinition(model, position, token) {
      const entry = entryByModel.get(model);
      if (!entry || token.isCancellationRequested) return null;

      const response = await requestLightweight("definition", entry, model, position);
      if (token.isCancellationRequested) return null;

      const [location] = navigationLocations(response);
      // Only same-document navigation is supported in this phase. A location in
      // another file is ignored instead of faking an open flow for it.
      if (!location || !sameDocumentPath(location.filePath, entry.filename)) return null;
      return { uri: model.uri, range: location.range };
    },
  });

  monaco.languages.registerReferenceProvider(LIGHTWEIGHT_LANGUAGE_SELECTOR, {
    async provideReferences(model, position, _context, token) {
      const entry = entryByModel.get(model);
      if (!entry || token.isCancellationRequested) return [];

      const response = await requestLightweight("references", entry, model, position);
      if (token.isCancellationRequested) return [];

      return navigationLocations(response)
        .filter((location) => sameDocumentPath(location.filePath, entry.filename))
        .map((location) => ({ uri: model.uri, range: location.range }));
    },
  });
}

/** Monaco theme colors require #RGB/#RRGGBB/#RRGGBBAA; Rust sends CSS colors. */
function toMonacoColor(value: string, fallback: string): string {
  const color = value.trim();
  if (/^#[0-9a-f]{3,8}$/i.test(color)) return color;
  const match = /^rgba?\(\s*([0-9.]+)\s*[, ]\s*([0-9.]+)\s*[, ]\s*([0-9.]+)(?:\s*[,/]\s*([0-9.]+))?\s*\)$/i.exec(color);
  if (!match) return fallback;
  const channels = match.slice(1, 4).map((channel) => {
    const channelValue = Number(channel);
    return Number.isFinite(channelValue) ? Math.max(0, Math.min(255, Math.round(channelValue))) : NaN;
  });
  if (channels.some((channel) => !Number.isFinite(channel))) return fallback;
  const alphaValue = match[4] === undefined ? 1 : Number(match[4]);
  const alpha = Number.isFinite(alphaValue) ? Math.max(0, Math.min(1, alphaValue)) : 1;
  const alphaHex = alpha < 1 ? Math.round(alpha * 255).toString(16).padStart(2, "0") : "";
  return `#${channels.map((channel) => channel.toString(16).padStart(2, "0")).join("")}${alphaHex}`;
}

function defineThemes(background: string, foreground: string): void {
  for (const [name, base] of [["lithe-dark", "vs-dark"], ["lithe-light", "vs"]] as const) {
    monaco.editor.defineTheme(name, {
      base,
      inherit: true,
      // Monaco 会把缺少 rules 当作 undefined 并在构建 token 主题时崩溃。
      rules: [],
      colors: {
        "editor.background": background,
        "editor.foreground": foreground,
      },
    });
  }
}

function applyConfigure(payload: LitheConfigurePayload): void {
  if (payload && typeof payload === "object") {
    if (typeof payload.dark === "boolean") appearance.dark = payload.dark;
    if (typeof payload.background === "string" && payload.background.trim()) {
      appearance.background = payload.background;
    }
    if (typeof payload.foreground === "string" && payload.foreground.trim()) {
      appearance.foreground = payload.foreground;
    }
    if (typeof payload.fontFamily === "string" && payload.fontFamily.trim()) {
      appearance.fontFamily = payload.fontFamily;
    }
    if (typeof payload.fontSize === "number" && Number.isFinite(payload.fontSize) && payload.fontSize > 0) {
      appearance.fontSize = payload.fontSize;
    }
    if (typeof payload.wrap === "boolean") appearance.wrap = payload.wrap;
    if (typeof payload.minimap === "boolean") appearance.minimap = payload.minimap;
    // Rust 按 Monaco 的选项形式发送 "on"/"off"；同时接受布尔值，保证旧宿主
    // 或手工调用 configure 时也能工作。
    const lineNumbers = (payload as { lineNumbers?: boolean | string }).lineNumbers;
    if (lineNumbers === "on") appearance.lineNumbers = true;
    else if (lineNumbers === "off") appearance.lineNumbers = false;
    else if (typeof lineNumbers === "boolean") appearance.lineNumbers = lineNumbers;
    if (typeof payload.scrollBeyondLastLine === "boolean") {
      appearance.scrollBeyondLastLine = payload.scrollBeyondLastLine;
    }
    // 共享类型还没收录这个字段，按 lineNumbers 的方式局部读取，保持对旧宿主兼容。
    const renderWhitespace = (payload as { renderWhitespace?: unknown }).renderWhitespace;
    if (typeof renderWhitespace === "boolean") appearance.renderWhitespace = renderWhitespace;
    const fontLigatures = (payload as { fontLigatures?: unknown }).fontLigatures;
    if (typeof fontLigatures === "boolean") appearance.fontLigatures = fontLigatures;
    const codeLens = (payload as { codeLens?: unknown }).codeLens;
    if (typeof codeLens === "boolean") appearance.codeLens = codeLens;
    const tabSize = (payload as { tabSize?: unknown }).tabSize;
    if (typeof tabSize === "number" && Number.isFinite(tabSize) && tabSize > 0) {
      appearance.tabSize = Math.floor(tabSize);
    }
  }

  const background = toMonacoColor(appearance.background, appearance.dark ? "#1e1e1e" : "#ffffff");
  const foreground = toMonacoColor(appearance.foreground, appearance.dark ? "#d4d4d4" : "#1f1f1f");
  defineThemes(background, foreground);
  monaco.editor.setTheme(appearance.dark ? "lithe-dark" : "lithe-light");

  editor?.updateOptions({
    fontFamily: appearance.fontFamily,
    fontSize: appearance.fontSize,
    wordWrap: appearance.wrap ? "on" : "off",
    minimap: { enabled: appearance.minimap },
    lineNumbers: appearance.lineNumbers ? "on" : "off",
    scrollBeyondLastLine: appearance.scrollBeyondLastLine,
    renderWhitespace: appearance.renderWhitespace ? "all" : "none",
    fontLigatures: appearance.fontLigatures,
    codeLens: appearance.codeLens,
    tabSize: appearance.tabSize,
    // 只读是分屏副窗格的状态，不属于外观；显式回填当前值，避免外观更新
    // 重设选项时把 setReadonly 的结果覆盖掉。
    readOnly,
  });

  document.documentElement.style.colorScheme = appearance.dark ? "dark" : "light";
  document.documentElement.style.background = appearance.background;
  document.body.style.background = appearance.background;
}

// window.lithe must exist before Monaco finishes booting; Rust may call open()
// before it has seen the ready message. Early opens are queued, not dropped.
window.lithe = {
  open(payload) {
    if (!editor) {
      pendingOpens.push(payload);
      return;
    }
    openFile(payload);
  },
  close(id) {
    closeFile(String(id));
  },
  clear() {
    clearEditor();
  },
  configure(payload) {
    applyConfigure(payload);
  },
  // 宿主菜单/命令面板的入口。菜单文案不会直接变成 JS：Rust 只转发白名单里的
  // Monaco action id，这里再交给命令服务执行。
  save() {
    saveActive();
  },
  command(name) {
    const id = typeof name === "string" ? name.trim() : "";
    if (id) editor?.trigger("lithe-menu", id, null);
  },
  focus() {
    editor?.focus();
  },
  resolve(requestId, value) {
    bridge.resolve(requestId, value);
  },
  setSaved(id, saved) {
    // Informational only: Rust owns the dirty flag and clears it itself.
    const entry = entries.get(String(id));
    if (!entry) return;
    entry.lastSaved = saved === true;
    // Rust 保存成功即认为模型干净；本地标记只服务于 Save All。
    if (saved === true) entry.dirty = false;
  },
  // saveAll / saveAs / setReadonly 由下方 Object.assign 补上；这里按 LitheApi 断言类型。
} as LitheApi;

// 宿主菜单入口在这里补运行时方法：
// - saveAll 还没收录进共享类型，只有运行时入口；
// - saveAs 的签名已在 protocol.ts 的 LitheApi 中，实现挂在上面的模块函数上；
// - setReadonly 供 Split Editor 副窗格切换只读，同样挂在模块函数上。
Object.assign(window.lithe, { saveAll, saveAs, setReadonly, revealLine });

defineThemes(
  toMonacoColor(appearance.background, "#1e1e1e"),
  toMonacoColor(appearance.foreground, "#d4d4d4"),
);

const container = document.getElementById("editor");
if (!container) throw new Error("Lithe editor: missing #editor container");

const view = monaco.editor.create(container, {
  theme: "lithe-dark",
  automaticLayout: true,
  scrollBeyondLastLine: appearance.scrollBeyondLastLine,
  minimap: { enabled: appearance.minimap },
  lineNumbers: appearance.lineNumbers ? "on" : "off",
  renderWhitespace: appearance.renderWhitespace ? "all" : "none",
  fontLigatures: appearance.fontLigatures,
  codeLens: appearance.codeLens,
  tabSize: appearance.tabSize,
  fontFamily: appearance.fontFamily,
  fontSize: appearance.fontSize,
  wordWrap: "off",
  readOnly: false,
});
editor = view;
registerLanguageProviders();

view.onDidChangeCursorPosition((event) => {
  if (!activeId) return;
  bridge.notify("cursor", {
    id: activeId,
    line: event.position.lineNumber - 1,
    column: event.position.column - 1,
  });
});

view.onDidFocusEditorText(() => {
  if (!activeId) return;
  const position = view.getPosition();
  bridge.notify("focus", {
    id: activeId,
    line: (position?.lineNumber ?? 1) - 1,
    column: (position?.column ?? 1) - 1,
  });
});

// 诊断是跨模型的：任一模型的 markers 变化都重新汇总全部已打开模型。
monaco.editor.onDidChangeMarkers(() => scheduleDiagnostics());

// Capture phase so the WebView never opens its own save dialog and Monaco's
// command service does not need a second keybinding registration.
document.addEventListener("keydown", (event) => {
  if (!(event.ctrlKey || event.metaKey) || event.altKey) return;
  if (event.key.toLowerCase() !== "s") return;
  event.preventDefault();
  event.stopPropagation();
  if (!event.repeat) saveActive();
}, true);

window.addEventListener("unhandledrejection", (event) => {
  reportFailure(event.reason);
});

// Applying queued opens before announcing ready keeps the host's ordering:
// open() calls made during page load are visible by the time Rust starts its
// message pump.
for (const payload of pendingOpens.splice(0)) openFile(payload);
bridge.notify("ready");
