import { expect, test } from "bun:test";
import {
  resolveDiagnosticsPaneUpdate,
  resolveGlobalSearchSidebarUpdate,
} from "./workbench-tool-window-actions";

test("global search opens the search sidebar", () => {
  expect(resolveGlobalSearchSidebarUpdate()).toEqual({
    activeSidebarView: "search",
    isSidebarVisible: true,
  });
});

test("diagnostics opens and toggles the bottom pane", () => {
  expect(
    resolveDiagnosticsPaneUpdate({
      bottomPaneActiveTab: "terminal",
      isBottomPaneVisible: false,
    }),
  ).toEqual({
    bottomPaneActiveTab: "diagnostics",
    isBottomPaneVisible: true,
  });

  expect(
    resolveDiagnosticsPaneUpdate({
      bottomPaneActiveTab: "diagnostics",
      isBottomPaneVisible: true,
    }),
  ).toEqual({
    bottomPaneActiveTab: "diagnostics",
    isBottomPaneVisible: false,
  });
});
