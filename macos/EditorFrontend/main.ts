import implementingMethod from "../Resources/IDEAIcons/gutter/implementingMethod.svg" with { type: "text" };
import implementedMethod from "../Resources/IDEAIcons/gutter/implementedMethod.svg" with { type: "text" };
import overridingMethod from "../Resources/IDEAIcons/gutter/overridingMethod.svg" with { type: "text" };
import overriddenMethod from "../Resources/IDEAIcons/gutter/overridenMethod.svg" with { type: "text" };
import runIcon from "../Resources/IDEAIcons/testState/run.svg" with { type: "text" };
import runAllIcon from "../Resources/IDEAIcons/testState/run_run.svg" with { type: "text" };
import passedIcon from "../Resources/IDEAIcons/testState/green2.svg" with { type: "text" };
import failedIcon from "../Resources/IDEAIcons/testState/red2.svg" with { type: "text" };
import { mountWorkbench } from "@lithe/editor/workbench";
import { KeyCode, KeyMod, editor as monacoEditor } from "monaco-editor/esm/vs/editor/editor.api.js";
import palette from "../Sources/Lithe/Resources/SyntaxHighlighting/color-mappings.json";
import { installWebKitMouseInput } from "./mouse-input";
import { StandaloneServices } from "monaco-editor/esm/vs/editor/standalone/browser/standaloneServices.js";
import { IContextMenuService } from "monaco-editor/esm/vs/platform/contextview/browser/contextView.js";
import { installNativeContextMenu, type MenuHandler } from "./context-menu";

declare global { interface Window { webkit: any; MonacoEnvironment: any; lithe: any; } }

// CoreText registration is process-local; remeasure after the bundled web fonts load.
document.fonts.ready.then(() => monacoEditor.remeasureFonts());

const mouseInput = installWebKitMouseInput(document);
window.addEventListener("beforeunload", () => mouseInput.dispose(), { once: true });

const workbench = mountWorkbench({
  request: payload => window.webkit.messageHandlers.litheEditor.postMessage(payload),
  palette,
  javaNavigationIcons: { "up-interface": implementingMethod, "down-interface": implementedMethod,
    "up-inheritance": overridingMethod, "down-inheritance": overriddenMethod },
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
