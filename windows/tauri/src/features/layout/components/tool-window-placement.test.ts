import { expect, test } from "bun:test";

test("Search and Diagnostics open in workbench tool windows", async () => {
  const sidebarSource = await Bun.file(
    new URL("./sidebar/main-sidebar.tsx", import.meta.url),
  ).text();
  const bottomPaneSource = await Bun.file(
    new URL("./bottom-pane/bottom-pane.tsx", import.meta.url),
  ).text();
  const viewActionsSource = await Bun.file(
    new URL("../../keymaps/commands/view-command-actions.ts", import.meta.url),
  ).text();

  expect(sidebarSource).toContain("<GlobalSearchBuffer compact />");
  expect(sidebarSource).toContain('handleSidebarViewChange("search")');
  expect(bottomPaneSource).toContain('bottomPaneActiveTab === "diagnostics"');
  expect(bottomPaneSource).toContain("<DiagnosticsBuffer");
  expect(viewActionsSource).not.toContain("actions.openGlobalSearchBuffer()");
  expect(viewActionsSource).not.toContain("actions.openDiagnosticsBuffer()");
});

test("ordinary code editors omit the unused ellipsis toolbar", async () => {
  const editorSource = await Bun.file(
    new URL("../../editor/components/code-editor.tsx", import.meta.url),
  ).text();

  expect(editorSource).toContain("showToolbar = false");
});
