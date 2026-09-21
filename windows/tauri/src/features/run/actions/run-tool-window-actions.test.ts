import { expect, test } from "bun:test";
import { resolveRunDecisionPaneUpdate } from "./run-tool-window-actions";

test("a Java launch decision opens the Run tool window", () => {
  expect(resolveRunDecisionPaneUpdate()).toEqual({
    bottomPaneActiveTab: "run",
    isBottomPaneVisible: true,
  });
});
