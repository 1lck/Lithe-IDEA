import * as monaco from "monaco-editor/esm/vs/editor/editor.api.js";
import "monaco-editor/esm/vs/editor/editor.all.js";
import { ensureMonacoLanguageTokenizer } from "./language-contributions";

export interface ReviewRow {
  id: string;
  oldLine: number | null;
  newLine: number | null;
  left: string | null;
  right: string | null;
  kind: "context" | "changed" | "addition" | "removal" | "information";
  hunkID?: string | null;
}
export interface ReviewAction { id: string; title: string }
export interface DiffReviewInput {
  rows: ReviewRow[];
  language: string;
  sideBySide?: boolean;
  collapse?: boolean;
  overview?: boolean;
  highlightWords?: boolean;
  ignoreTrimWhitespace?: boolean;
  actions?: ReviewAction[];
}
export interface ReviewSelection {
  selectedIDs?: string[];
  matches?: { rowID: string; startColumn: number; endColumn: number; current?: boolean }[];
  searchIDs?: string[];
  currentID?: string | null;
  revealID?: string | null;
}

/** A review projection, not a writable source document. Missing patch context is
 * never invented and displayed line numbers always come from the Git/history host. */
export function projectReviewRows(rows: ReviewRow[], side: "left" | "right") {
  const visible = rows.filter(row => row[side] !== null);
  return { rows: visible, text: visible.map(row => row[side]!).join("\n") };
}

let nextReviewID = 0;
export function mountDiffReview(container: HTMLElement,
  onAction: (hunkID: string, action: string) => void = () => {}) {
  container.classList.add("lithe-diff-review");
  const style = document.createElement("style");
  style.textContent = `
    .lithe-diff-review .lithe-review-information { opacity:.65; font-style:italic }
    .lithe-diff-review .lithe-review-selected { background:rgba(80,140,220,.14) }
    .lithe-diff-review .lithe-review-search { background:rgba(220,180,40,.20) }
    .lithe-diff-review .lithe-review-current { outline:1px solid rgba(220,180,40,.8) }
    .lithe-diff-review.no-word-highlights .char-insert,
    .lithe-diff-review.no-word-highlights .char-delete { background:transparent!important }
    .lithe-review-actions { display:flex; align-items:center; gap:8px; padding:0 12px; box-sizing:border-box; font:12px system-ui }
    .lithe-review-actions button { color:inherit; background:transparent; border:1px solid currentColor; border-radius:3px; cursor:pointer }
  `;
  container.append(style);
  const root = document.createElement("div");
  root.style.cssText = "height:100%;width:100%";
  container.append(root);
  const editor = monaco.editor.createDiffEditor(root, {
    automaticLayout: true, readOnly: true, originalEditable: false,
    renderSideBySide: true, useInlineViewWhenSpaceIsLimited: false,
    renderOverviewRuler: true, renderMarginRevertIcon: false,
    enableSplitViewResizing: true, scrollBeyondLastLine: false,
    minimap: { enabled: false }, stickyScroll: { enabled: false },
    ignoreTrimWhitespace: false, diffAlgorithm: "advanced",
    maxComputationTime: 10_000,
  });
  const instanceID = ++nextReviewID;
  const original = monaco.editor.createModel("", "plaintext", monaco.Uri.parse(`lithe-review://${instanceID}/original`));
  const modified = monaco.editor.createModel("", "plaintext", monaco.Uri.parse(`lithe-review://${instanceID}/modified`));
  editor.setModel({ original, modified });
  const left = editor.getOriginalEditor(), right = editor.getModifiedEditor();
  const leftDecorations = left.createDecorationsCollection();
  const rightDecorations = right.createDecorationsCollection();
  let leftRows: ReviewRow[] = [], rightRows: ReviewRow[] = [];
  let zones: { view: monaco.editor.ICodeEditor; ids: string[] }[] = [];
  let version = 0, disposed = false;
  let latestSelection: ReviewSelection = {};
  let revealedID: string | null | undefined;

  function clearZones() {
    for (const zone of zones) zone.view.changeViewZones(accessor => zone.ids.forEach(id => accessor.removeZone(id)));
    zones = [];
  }
  function updateSelection(selection: ReviewSelection) {
    latestSelection = selection;
    const selected = new Set(selection.selectedIDs), searched = new Set(selection.searchIDs);
    const matchesByRow = new Map<string, NonNullable<ReviewSelection["matches"]>>();
    for (const match of selection.matches ?? []) {
      const matches = matchesByRow.get(match.rowID) ?? [];
      matches.push(match); matchesByRow.set(match.rowID, matches);
    }
    for (const [rows, decorations] of [[leftRows, leftDecorations], [rightRows, rightDecorations]] as const) {
      decorations.set(rows.flatMap((row, index) => {
        const classes = [row.kind === "information" ? "lithe-review-information" : "",
          selected.has(row.id) ? "lithe-review-selected" : "", searched.has(row.id) ? "lithe-review-search" : "",
          selection.currentID === row.id ? "lithe-review-current" : ""].filter(Boolean).join(" ");
        const decorations: monaco.editor.IModelDeltaDecoration[] = classes ? [{
          range: new monaco.Range(index + 1, 1, index + 1, 1), options: { isWholeLine: true, className: classes },
        }] : [];
        for (const match of matchesByRow.get(row.id) ?? []) {
          decorations.push({ range: new monaco.Range(index + 1, match.startColumn, index + 1, match.endColumn),
            options: { inlineClassName: match.current ? "lithe-review-current" : "lithe-review-search" } });
        }
        return decorations;
      }));
    }
    const currentMatch = selection.matches?.find(match => match.current && match.rowID === selection.revealID);
    const revealKey = JSON.stringify([selection.revealID, currentMatch?.startColumn, currentMatch?.endColumn]);
    if (selection.revealID && revealKey !== revealedID) {
      revealedID = revealKey;
      const rightIndex = rightRows.findIndex(row => row.id === selection.revealID);
      const leftIndex = leftRows.findIndex(row => row.id === selection.revealID);
      const view = rightIndex >= 0 ? right : left;
      const index = rightIndex >= 0 ? rightIndex : leftIndex;
      if (index >= 0) {
        if (currentMatch) view.setSelection(new monaco.Range(index + 1, currentMatch.startColumn, index + 1, currentMatch.endColumn));
        else view.setPosition({ lineNumber: index + 1, column: 1 });
        view.revealLineInCenter(index + 1, monaco.editor.ScrollType.Immediate);
      }
    }
  }
  return {
    editor,
    async update(input: DiffReviewInput) {
      const request = ++version;
      await ensureMonacoLanguageTokenizer(input.language);
      if (disposed || request !== version) return;
      // Capture the scroll anchor while the previous action zones still occupy
      // their space. Monaco restores by first visible line, so saving after the
      // zones are removed shifts every update down by the zone heights above
      // the viewport.
      const viewState = editor.saveViewState();
      clearZones();
      const old = projectReviewRows(input.rows, "left"), next = projectReviewRows(input.rows, "right");
      leftRows = old.rows; rightRows = next.rows;
      if (original.getLanguageId() !== input.language) monaco.editor.setModelLanguage(original, input.language);
      if (modified.getLanguageId() !== input.language) monaco.editor.setModelLanguage(modified, input.language);
      if (original.getValue() !== old.text) original.setValue(old.text);
      if (modified.getValue() !== next.text) modified.setValue(next.text);
      left.updateOptions({ lineNumbers: line => String(leftRows[line - 1]?.oldLine ?? "") });
      right.updateOptions({ lineNumbers: line => String(rightRows[line - 1]?.newLine ?? "") });
      editor.updateOptions({ renderSideBySide: input.sideBySide ?? true,
        hideUnchangedRegions: { enabled: input.collapse ?? true, contextLineCount: 3, minimumLineCount: 8 },
        renderOverviewRuler: input.overview ?? true, ignoreTrimWhitespace: input.ignoreTrimWhitespace ?? false });
      container.classList.toggle("no-word-highlights", input.highlightWords === false);
      const actions = input.actions ?? [];
      if (actions.length) {
        for (const [view, rows] of [[left, leftRows], [right, rightRows]] as const) {
          const ids: string[] = [];
          view.changeViewZones(accessor => {
            rows.forEach((row, index) => {
              if (row.kind !== "information" || !row.hunkID) return;
              const node = document.createElement("div");
              node.className = "lithe-review-actions";
              if (view === right) for (const action of actions) {
                const button = document.createElement("button");
                button.textContent = action.title;
                button.onclick = () => { if (!disposed && request === version) onAction(row.hunkID!, action.id); };
                node.append(button);
              }
              ids.push(accessor.addZone({ afterLineNumber: index + 1, heightInPx: 26, domNode: node }));
            });
          });
          zones.push({ view, ids });
        }
      }
      if (viewState) editor.restoreViewState(viewState);
      revealedID = undefined;
      updateSelection(latestSelection);
    },
    select: updateSelection,
    configure(options: monaco.editor.IDiffEditorOptions) { editor.updateOptions(options); },
    dispose() {
      if (disposed) return;
      disposed = true; version++;
      clearZones(); leftDecorations.clear(); rightDecorations.clear();
      editor.setModel(null); editor.dispose(); original.dispose(); modified.dispose(); root.remove(); style.remove();
      container.classList.remove("lithe-diff-review", "no-word-highlights");
    },
  };
}
