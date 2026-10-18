import implementingMethod from "../Resources/IDEAIcons/gutter/implementingMethod.svg" with { type: "text" };
import implementedMethod from "../Resources/IDEAIcons/gutter/implementedMethod.svg" with { type: "text" };
import overridingMethod from "../Resources/IDEAIcons/gutter/overridingMethod.svg" with { type: "text" };
import overriddenMethod from "../Resources/IDEAIcons/gutter/overridenMethod.svg" with { type: "text" };
import runIcon from "../Resources/IDEAIcons/expui/run/run.svg" with { type: "text" };
import runIconDark from "../Resources/IDEAIcons/expui/run/run_dark.svg" with { type: "text" };
import runAllIcon from "../Resources/IDEAIcons/expui/actions/runAll.svg" with { type: "text" };
import runAllIconDark from "../Resources/IDEAIcons/expui/actions/runAll_dark.svg" with { type: "text" };
import passedIcon from "../Resources/IDEAIcons/expui/gutter/runSuccess.svg" with { type: "text" };
import passedIconDark from "../Resources/IDEAIcons/expui/gutter/runSuccess_dark.svg" with { type: "text" };
import failedIcon from "../Resources/IDEAIcons/expui/gutter/runError.svg" with { type: "text" };
import failedIconDark from "../Resources/IDEAIcons/expui/gutter/runError_dark.svg" with { type: "text" };
import foldIcon from "../Resources/IDEAIcons/expui/gutter/fold.svg" with { type: "text" };
import foldIconDark from "../Resources/IDEAIcons/expui/gutter/fold_dark.svg" with { type: "text" };
import unfoldIcon from "../Resources/IDEAIcons/expui/gutter/unfold.svg" with { type: "text" };
import unfoldIconDark from "../Resources/IDEAIcons/expui/gutter/unfold_dark.svg" with { type: "text" };
import { mountWorkbench } from "@lithe/editor/workbench";
import { KeyCode, KeyMod, editor as monacoEditor } from "monaco-editor/esm/vs/editor/editor.api.js";
import { EditorOptions } from "monaco-editor/esm/vs/editor/common/config/editorOptions.js";
import { BareFontInfo } from "monaco-editor/esm/vs/editor/common/config/fontInfo.js";
import type { TextModel } from "monaco-editor/esm/vs/editor/common/model/textModel.js";
import { FontMeasurements } from "monaco-editor/esm/vs/editor/browser/config/fontMeasurements.js";
import palette from "../Sources/Lithe/Resources/SyntaxHighlighting/color-mappings.json";
import { installWebKitMouseInput } from "./mouse-input";
import { StandaloneServices } from "monaco-editor/esm/vs/editor/standalone/browser/standaloneServices.js";
import { IContextMenuService } from "monaco-editor/esm/vs/platform/contextview/browser/contextView.js";
import { installNativeContextMenu, type MenuHandler } from "./context-menu";
import "./ime-input.css";

declare global { interface Window { webkit: any; MonacoEnvironment: any; lithe: any; } }

// CoreText registration is process-local; remeasure after the bundled web fonts load.
document.fonts.ready.then(() => monacoEditor.remeasureFonts());

const mouseInput = installWebKitMouseInput(document);
window.addEventListener("beforeunload", () => mouseInput.dispose(), { once: true });

// Monaco 0.55.1 uses maxDigitWidth only for the number column in layoutInfo.
// Adapt that input, so upstream still owns content width, wrapping, minimap and hit testing.
const computeEditorLayout = EditorOptions.layoutInfo.compute;
EditorOptions.layoutInfo.compute = function (env, options, value) {
  const nativeGutter = options.get(EditorOptions.extraEditorClassName.id).split(" ").includes("lithe-line-numbers-first");
  if (!nativeGutter || options.get(EditorOptions.lineNumbers.id).renderFn) {
    return computeEditorLayout.call(this, env, options, value);
  }
  const font = FontMeasurements.readFontInfo(window, new BareFontInfo({
    ...env.fontInfo, fontWeight: "normal", fontSize: Math.max(1, env.fontInfo.fontSize - 1),
  }));
  const digits = Math.max(1, env.lineNumbersDigitCount);
  const width = Math.max(16, digits * font.maxDigitWidth);
  return computeEditorLayout.call(this, {
    ...env, fontInfo: { ...env.fontInfo, maxDigitWidth: width / digits },
  }, options, value);
};

// Use Monaco's token-aware bracket matcher; do not infer scope from indentation alone.
const indentGuideEditors = monacoEditor.onDidCreateEditor(view => {
  if (!view.getRawOptions().extraEditorClassName?.split(" ").includes("lithe-line-numbers-first")) return;
  let refreshing = false;
  let tokens: { dispose(): void } | undefined;
  const refresh = () => {
    const model = view.getModel(), position = view.getPosition();
    if (!model || !position || refreshing) return;
    refreshing = true;
    try {
      // bracketPairs belongs to the pinned upstream TextModel (Monaco 0.55.1).
      const textModel = model as TextModel;
      const pair = textModel.bracketPairs.matchBracket(position, 5);
      const active = view.getSelection()?.isEmpty() && pair &&
        pair[0].startLineNumber !== pair[1].startLineNumber &&
        pair.every(range => {
          const tokens = textModel.tokenization.getLineTokens(range.startLineNumber);
          return tokens.getStandardTokenType(tokens.findTokenIndexAtOffset(range.startColumn - 1)) === 0; // StandardTokenType.Other
        }) &&
        pair.some(range => model.getValueInRange(range) === "{") &&
        pair.some(range => model.getValueInRange(range) === "}");
      const bracketPairs = active ? "active" : false;
      const guides = view.getOption(monacoEditor.EditorOption.guides);
      if (guides.bracketPairs !== bracketPairs || guides.highlightActiveIndentation) {
        view.updateOptions({ guides: { bracketPairs, bracketPairsHorizontal: false, highlightActiveIndentation: false } });
      }
    } finally { refreshing = false; }
  };
  const bind = () => {
    tokens?.dispose();
    tokens = view.getModel()?.onDidChangeTokens(refresh);
    refresh();
  };
  const listeners = [view.onDidChangeCursorSelection(refresh), view.onDidChangeModel(bind),
    view.onDidChangeModelContent(refresh), view.onDidChangeConfiguration(event => {
      if (event.hasChanged(monacoEditor.EditorOption.guides)) refresh();
    })];
  bind();
  view.onDidDispose(() => { tokens?.dispose(); listeners.forEach(listener => listener.dispose()); });
});
window.addEventListener("beforeunload", () => indentGuideEditors.dispose(), { once: true });

const workbench = mountWorkbench({
  request: payload => window.webkit.messageHandlers.litheEditor.postMessage(payload),
  palette,
  javaNavigationIcons: { "up-interface": implementingMethod, "down-interface": implementedMethod,
    "up-inheritance": overridingMethod, "down-inheritance": overriddenMethod },
  lineNumbersFirst: true,
  foldingIcons: { expanded: { light: foldIcon, dark: foldIconDark },
    collapsed: { light: unfoldIcon, dark: unfoldIconDark } },
  javaRunIconsDark: { run: runIconDark, "run-all": runAllIconDark, passed: passedIconDark, failed: failedIconDark },
  javaRunIcons: { run: runIcon, "run-all": runAllIcon, passed: passedIcon, failed: failedIcon },
  keybindings: [
    { command: "editor.action.duplicateSelection", label: "Duplicate Line or Selection", keybinding: KeyMod.CtrlCmd | KeyCode.KeyD },
    { command: "editor.action.moveLinesUpAction", label: "Move Line Up", keybinding: KeyMod.Alt | KeyMod.Shift | KeyCode.UpArrow },
    { command: "editor.action.moveLinesDownAction", label: "Move Line Down", keybinding: KeyMod.Alt | KeyMod.Shift | KeyCode.DownArrow },
  ],
});
const menus = installNativeContextMenu(
  (StandaloneServices.get(IContextMenuService) as unknown as { contextMenuHandler: MenuHandler }).contextMenuHandler,
  payload => window.webkit.messageHandlers.litheEditor.postMessage(payload), document);
window.addEventListener("beforeunload", () => menus.dispose(), { once: true });
window.lithe = workbench.api;
export const ready = workbench.ready;
