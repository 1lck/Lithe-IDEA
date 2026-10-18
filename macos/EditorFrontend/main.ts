import softWrapIcon from "../Resources/IDEAIcons/expui/general/softWrap.svg" with { type: "text" };
import softWrapIconDark from "../Resources/IDEAIcons/expui/general/softWrap_dark.svg" with { type: "text" };
import intentionBulb from "../Resources/IDEAIcons/expui/codeInsight/intentionBulb.svg" with { type: "text" };
import intentionBulbDark from "../Resources/IDEAIcons/expui/codeInsight/intentionBulb_dark.svg" with { type: "text" };
import breakpointValid from "../Resources/IDEAIcons/expui/breakpoints/breakpointValid.svg" with { type: "text" };
import breakpointValidDark from "../Resources/IDEAIcons/expui/breakpoints/breakpointValid_dark.svg" with { type: "text" };
import breakpointUnsuspendentValid from "../Resources/IDEAIcons/expui/breakpoints/breakpointUnsuspendentValid.svg" with { type: "text" };
import breakpointUnsuspendentValidDark from "../Resources/IDEAIcons/expui/breakpoints/breakpointUnsuspendentValid_dark.svg" with { type: "text" };
import breakpoint from "../Resources/IDEAIcons/expui/breakpoints/breakpoint.svg" with { type: "text" };
import breakpointDark from "../Resources/IDEAIcons/expui/breakpoints/breakpoint_dark.svg" with { type: "text" };
import breakpointDisabled from "../Resources/IDEAIcons/expui/breakpoints/breakpointDisabled.svg" with { type: "text" };
import breakpointDisabledDark from "../Resources/IDEAIcons/expui/breakpoints/breakpointDisabled_dark.svg" with { type: "text" };
import breakpointMuted from "../Resources/IDEAIcons/expui/breakpoints/breakpointMuted.svg" with { type: "text" };
import breakpointMutedDark from "../Resources/IDEAIcons/expui/breakpoints/breakpointMuted_dark.svg" with { type: "text" };
import breakpointMutedDisabled from "../Resources/IDEAIcons/expui/breakpoints/breakpointMutedDisabled.svg" with { type: "text" };
import breakpointMutedDisabledDark from "../Resources/IDEAIcons/expui/breakpoints/breakpointMutedDisabled_dark.svg" with { type: "text" };
import breakpointInvalid from "../Resources/IDEAIcons/expui/breakpoints/breakpointInvalid.svg" with { type: "text" };
import breakpointInvalidDark from "../Resources/IDEAIcons/expui/breakpoints/breakpointInvalid_dark.svg" with { type: "text" };
import breakpointUnsuspendent from "../Resources/IDEAIcons/expui/breakpoints/breakpointUnsuspendent.svg" with { type: "text" };
import breakpointUnsuspendentDark from "../Resources/IDEAIcons/expui/breakpoints/breakpointUnsuspendent_dark.svg" with { type: "text" };
import breakpointUnsuspendentDisabled from "../Resources/IDEAIcons/expui/breakpoints/breakpointUnsuspendentDisabled.svg" with { type: "text" };
import breakpointUnsuspendentDisabledDark from "../Resources/IDEAIcons/expui/breakpoints/breakpointUnsuspendentDisabled_dark.svg" with { type: "text" };
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
  // IDEA 262 New UI: 4pt empty annotation area + 4pt gap before the number column.
  // Breakpoints replace numbers inside that column; they are not another leading slot.
  const leadingInset = 8;
  const width = leadingInset + Math.max(16, digits * font.maxDigitWidth);
  return computeEditorLayout.call(this, {
    ...env, fontInfo: { ...env.fontInfo, maxDigitWidth: width / digits },
  }, options, value);
};

// One WebKit hit target owns the soft-wrap button and its cursor; no native overlay competes with it.
const softWrapButton = document.createElement("button");
softWrapButton.type = "button";
softWrapButton.className = "lithe-soft-wrap";
softWrapButton.hidden = true;
softWrapButton.addEventListener("mousedown", event => event.preventDefault());
softWrapButton.addEventListener("click", event => {
  event.stopPropagation();
  if (!softWrapButton.disabled && !softWrapButton.hidden)
    void window.webkit.messageHandlers.litheEditor.postMessage({ type: "toggleSoftWrap" }).catch(console.error);
});
document.body.append(softWrapButton);
const positionSoftWrapButton = (view: monacoEditor.IStandaloneCodeEditor) => {
  if (!view.getDomNode()?.closest("#editor")) return;
  const layout = view.getLayoutInfo();
  const inset = layout.minimap.minimapWidth > 0 ? layout.width - layout.minimap.minimapLeft : layout.verticalScrollbarWidth;
  softWrapButton.style.right = `${inset + 8}px`;
  softWrapButton.dataset.dark = String(view.getDomNode()!.classList.contains("vs-dark"));
};
const editorControlStyle = document.createElement("style");
editorControlStyle.textContent = `
  .lithe-soft-wrap {position:fixed;top:8px;z-index:5;border:0;padding:0;cursor:pointer;
    width:var(--lithe-wrap-size);height:var(--lithe-wrap-size);border-radius:var(--lithe-wrap-radius);
    background:transparent url("data:image/svg+xml,${encodeURIComponent(softWrapIcon)}") center/16px 16px no-repeat}
  .lithe-soft-wrap[data-dark="true"] {background-image:url("data:image/svg+xml,${encodeURIComponent(softWrapIconDark)}")}
  .lithe-soft-wrap:enabled:hover {background-color:var(--lithe-wrap-hover)}
  .lithe-soft-wrap:enabled:is(:active,[aria-pressed="true"]) {background-color:var(--lithe-wrap-pressed)}
  .lithe-soft-wrap:disabled {opacity:var(--lithe-wrap-disabled-opacity);cursor:default}
  .monaco-editor.lithe-line-numbers-first :is(.lightBulbWidget,.cgmr[class*="codicon-gutter-lightbulb"]):before {
    content:""!important;display:inline-block;width:16px;height:16px;background:center/16px 16px no-repeat;
    background-image:url("data:image/svg+xml,${encodeURIComponent(intentionBulb)}")}
  .monaco-editor.vs-dark.lithe-line-numbers-first :is(.lightBulbWidget,.cgmr[class*="codicon-gutter-lightbulb"]):before {
    background-image:url("data:image/svg+xml,${encodeURIComponent(intentionBulbDark)}")}

`;
document.head.append(editorControlStyle);

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
  const listeners = [view.onDidLayoutChange(() => positionSoftWrapButton(view)),
    view.onDidChangeCursorSelection(refresh), view.onDidChangeModel(bind),
    view.onDidChangeModelContent(refresh), view.onDidChangeConfiguration(event => {
      positionSoftWrapButton(view);
      if (event.hasChanged(monacoEditor.EditorOption.guides) || event.hasChanged(monacoEditor.EditorOption.readOnly) ||
          event.hasChanged(monacoEditor.EditorOption.lineNumbers)) refresh();
    })];
  bind();
  view.onDidDispose(() => { tokens?.dispose(); listeners.forEach(listener => listener.dispose()); });
});
window.addEventListener("beforeunload", () => indentGuideEditors.dispose(), { once: true });

// IDEA New UI uses original 14pt SVGs, independent of Codicon font metrics.
const breakpointStyle = document.createElement("style");
const breakpointIcons = {
  valid: [breakpointValid, breakpointValidDark], logpointValid: [breakpointUnsuspendentValid, breakpointUnsuspendentValidDark],
  regular: [breakpoint, breakpointDark], disabled: [breakpointDisabled, breakpointDisabledDark],
  muted: [breakpointMuted, breakpointMutedDark], mutedDisabled: [breakpointMutedDisabled, breakpointMutedDisabledDark],
  invalid: [breakpointInvalid, breakpointInvalidDark], logpoint: [breakpointUnsuspendent, breakpointUnsuspendentDark],
  logpointDisabled: [breakpointUnsuspendentDisabled, breakpointUnsuspendentDisabledDark],
};
breakpointStyle.textContent = `
  .monaco-editor.lithe-line-numbers-first .line-numbers.lithe-breakpoint,
  .monaco-editor.lithe-line-numbers-first[data-lithe-breakpoints-editable] .line-numbers:hover {height:100%;font-size:0}
  .monaco-editor.lithe-line-numbers-first[data-lithe-breakpoints-editable] .line-numbers {cursor:pointer}
  .monaco-editor.lithe-line-numbers-first .line-numbers.lithe-breakpoint:before,
  .monaco-editor.lithe-line-numbers-first[data-lithe-breakpoints-editable] .line-numbers:hover:before {
    content:""!important;position:absolute;right:1px;top:50%;transform:translateY(-50%);
    width:14px;height:14px;font-size:0!important;background-size:14px 14px;background-repeat:no-repeat;
  }
  .monaco-editor.lithe-line-numbers-first[data-lithe-breakpoints-editable] .line-numbers:not(.lithe-breakpoint):hover:before {
    background-image:url("data:image/svg+xml,${encodeURIComponent(breakpoint)}");opacity:0.3;
  }
  .monaco-editor.vs-dark.lithe-line-numbers-first[data-lithe-breakpoints-editable] .line-numbers:not(.lithe-breakpoint):hover:before {
    background-image:url("data:image/svg+xml,${encodeURIComponent(breakpointDark)}");opacity:0.35;
  }
  .monaco-editor.lithe-line-numbers-first .lithe-breakpoint-line {background:#FAEAE6}
  .monaco-editor.vs-dark.lithe-line-numbers-first .lithe-breakpoint-line {background:#40252B}
  /* IDEA EXECUTIONPOINT_ATTRIBUTES and DEBUGGER_INLINED_VALUES_EXECUTION_LINE. */
  .monaco-editor.lithe-line-numbers-first .lithe-execution-line {background:#2154A6}
  .monaco-editor.vs-dark.lithe-line-numbers-first .lithe-execution-line {background:#2A5091}
  .monaco-editor.lithe-line-numbers-first .lithe-debug-value {color:#A9B7D6;background:transparent}
  .monaco-editor.vs-dark.lithe-line-numbers-first .lithe-debug-value {color:#849FBF}
  ${Object.entries(breakpointIcons).flatMap(([state, icons]) => icons.map((svg, index) =>
    `.monaco-editor${index ? ".vs-dark" : ""}.lithe-line-numbers-first .line-numbers.lithe-breakpoint-${state}:before{background-image:url("data:image/svg+xml,${encodeURIComponent(svg)}")}`)).join("\n")}
`;
document.head.append(breakpointStyle);

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
const configureWorkbench = workbench.api.configure;
window.lithe = Object.assign(workbench.api, {
  configure(payload: Parameters<typeof configureWorkbench>[0]) {
    configureWorkbench(payload);
    for (const view of monacoEditor.getEditors()) positionSoftWrapButton(view);
  },
  softWrapControl(payload: { visible: boolean; enabled: boolean; selected: boolean; label: string; title: string;
      size: number; radius: number; disabledOpacity: number; hover: string; pressed: string }) {
    softWrapButton.hidden = !payload.visible;
    softWrapButton.disabled = !payload.enabled;
    softWrapButton.title = payload.title;
    softWrapButton.setAttribute("aria-label", payload.label);
    softWrapButton.setAttribute("aria-pressed", String(payload.selected));
    for (const [name, value] of Object.entries({ size: `${payload.size}px`, radius: `${payload.radius}px`,
      "disabled-opacity": String(payload.disabledOpacity), hover: payload.hover, pressed: payload.pressed }))
      softWrapButton.style.setProperty(`--lithe-wrap-${name}`, value);
    for (const view of monacoEditor.getEditors()) positionSoftWrapButton(view);
  },
});
export const ready = workbench.ready;
