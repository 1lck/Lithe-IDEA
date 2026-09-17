import type { editor } from "monaco-editor";

const actions = {
  duplicateLine: "editor.action.duplicateSelection",
  deleteLine: "editor.action.deleteLines",
  toggleComment: "editor.action.commentLine",
  moveLineUp: "editor.action.moveLinesUpAction",
  moveLineDown: "editor.action.moveLinesDownAction",
  copyLineUp: "editor.action.copyLinesUpAction",
  copyLineDown: "editor.action.copyLinesDownAction",
  goToMatchingBracket: "editor.action.jumpToBracket",
  removeBrackets: "editor.action.removeBrackets",
  expandSelection: "editor.action.smartSelect.expand",
  shrinkSelection: "editor.action.smartSelect.shrink",
  foldAll: "editor.foldAll",
  unfoldAll: "editor.unfoldAll",
} as const;

export type EditorCommand =
  | { type: keyof typeof actions }
  | { type: "selectToBracket"; selectBrackets: boolean }
  | { type: "foldLevel"; level: number }
  | { type: "find"; replace: boolean };

const editingCommands = new Set<EditorCommand["type"]>([
  "duplicateLine", "deleteLine", "toggleComment", "moveLineUp", "moveLineDown",
  "copyLineUp", "copyLineDown", "removeBrackets",
]);

// Menus and keymaps use the same Monaco actions as editor interaction. Host
// policy (preview/read-only/closing) is checked before invoking mutating actions.
export async function runEditorCommand(
  view: editor.IStandaloneCodeEditor,
  command: EditorCommand,
  writable: boolean,
): Promise<void> {
  if (!view.getModel() || (!writable && editingCommands.has(command.type))) return;
  let id: string;
  let args: object | undefined;
  switch (command.type) {
    case "find":
      id = command.replace ? "editor.action.startFindReplaceAction" : "actions.find";
      break;
    case "selectToBracket":
      id = "editor.action.selectToBracket";
      args = { selectBrackets: command.selectBrackets };
      break;
    case "foldLevel":
      if (!Number.isInteger(command.level) || command.level < 1 || command.level > 7) return;
      id = `editor.foldLevel${command.level}`;
      break;
    default:
      id = actions[command.type];
  }
  const action = view.getAction(id);
  if (!action) throw new Error(`Editor action unavailable: ${id}`);
  // Focus before the action: find/replace must retain focus in its own input.
  view.focus();
  await action.run(args);
}
