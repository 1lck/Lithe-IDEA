import type { editor } from "monaco-editor/esm/vs/editor/editor.api.js";

type HighlightContribution = editor.IEditorContribution & {
  wordHighlighter: { _run(...args: unknown[]): Promise<void> } | null;
};

/** Keep Monaco 0.55.1's queued highlighting bound to its original model.
 * Its `_run` reads the view's current model before validating that it exists.
 * Reuse the upstream highlighter; only reject callbacks whose owner has closed
 * or been replaced. Recheck this compatibility hook when upgrading Monaco.
 * Note: .agents/notes/implemented/architecture/2026-09-15-macos-monaco-feasibility-probe.md
 */
export function installWordHighlightLifecycle(view: editor.ICodeEditor): void {
  const guarded = new WeakSet<object>();
  const bind = () => {
    const model = view.getModel();
    const highlighter = view.getContribution<HighlightContribution>("editor.contrib.wordHighlighter")?.wordHighlighter;
    if (!model || !highlighter || guarded.has(highlighter)) return;
    guarded.add(highlighter);
    const run = highlighter._run;
    highlighter._run = async function (...args) {
      if (model.isDisposed() || view.getModel() !== model) return;
      return run.apply(this, args);
    };
  };
  bind();
  // The eager upstream contribution creates its new highlighter first. This
  // listener then binds that instance; the view owns both listener lifetimes.
  const changed = view.onDidChangeModel(bind);
  view.onDidDispose(() => changed.dispose());
}
