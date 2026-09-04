import { expect, test } from "bun:test";
import {
  resolveMavenRunPaneToggleUpdate,
  resolveMavenRunPaneUpdate,
} from "./maven-tool-window-actions";

test("Maven execution opens its bottom run pane", () => {
  expect(resolveMavenRunPaneUpdate()).toEqual({
    bottomPaneActiveTab: "maven",
    isBottomPaneVisible: true,
  });
});

test("Maven output can be restored after another bottom tab is active", () => {
  expect(
    resolveMavenRunPaneToggleUpdate({
      bottomPaneActiveTab: "terminal",
      isBottomPaneVisible: true,
    }),
  ).toEqual({
    bottomPaneActiveTab: "maven",
    isBottomPaneVisible: true,
  });
});

test("minimized Maven output reopens without changing its active tab", () => {
  expect(
    resolveMavenRunPaneToggleUpdate({
      bottomPaneActiveTab: "maven",
      isBottomPaneVisible: false,
    }),
  ).toEqual({
    bottomPaneActiveTab: "maven",
    isBottomPaneVisible: true,
  });
});

test("Maven output activity toggles the active bottom pane", () => {
  expect(
    resolveMavenRunPaneToggleUpdate({
      bottomPaneActiveTab: "maven",
      isBottomPaneVisible: true,
    }),
  ).toEqual({
    bottomPaneActiveTab: "maven",
    isBottomPaneVisible: false,
  });
});
