import implementingMethod from "../Resources/IDEAIcons/gutter/implementingMethod.svg" with { type: "text" };
import implementedMethod from "../Resources/IDEAIcons/gutter/implementedMethod.svg" with { type: "text" };
import overridingMethod from "../Resources/IDEAIcons/gutter/overridingMethod.svg" with { type: "text" };
import overriddenMethod from "../Resources/IDEAIcons/gutter/overridenMethod.svg" with { type: "text" };
import runIcon from "../Resources/IDEAIcons/testState/run.svg" with { type: "text" };
import runAllIcon from "../Resources/IDEAIcons/testState/run_run.svg" with { type: "text" };
import passedIcon from "../Resources/IDEAIcons/testState/green2.svg" with { type: "text" };
import failedIcon from "../Resources/IDEAIcons/testState/red2.svg" with { type: "text" };
import { mountWorkbench } from "@lithe/editor/workbench";
import { KeyCode, KeyMod } from "monaco-editor/esm/vs/editor/editor.api.js";
import palette from "../Sources/Lithe/Resources/SyntaxHighlighting/color-mappings.json";

declare global { interface Window { webkit: any; MonacoEnvironment: any; lithe: any; } }

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
window.lithe = workbench.api;
export const ready = workbench.ready;
