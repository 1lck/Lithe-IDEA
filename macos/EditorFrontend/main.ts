import { mountWorkbench } from "@lithe/editor/workbench";
import { KeyCode, KeyMod } from "monaco-editor/esm/vs/editor/editor.api.js";
import palette from "../Sources/Lithe/Resources/SyntaxHighlighting/color-mappings.json";

declare global { interface Window { webkit: any; MonacoEnvironment: any; lithe: any; } }

const workbench = mountWorkbench({
  request: payload => window.webkit.messageHandlers.litheEditor.postMessage(payload),
  palette,
  keybindings: [
    { command: "editor.action.duplicateSelection", label: "Duplicate Line or Selection", keybinding: KeyMod.CtrlCmd | KeyCode.KeyD },
    { command: "editor.action.moveLinesUpAction", label: "Move Line Up", keybinding: KeyMod.Alt | KeyMod.Shift | KeyCode.UpArrow },
    { command: "editor.action.moveLinesDownAction", label: "Move Line Down", keybinding: KeyMod.Alt | KeyMod.Shift | KeyCode.DownArrow },
  ],
});
window.lithe = workbench.api;
export const ready = workbench.ready;
