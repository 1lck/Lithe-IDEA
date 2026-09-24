import { expect, test } from "bun:test";
import { resolveMavenRunPaneUpdate } from "./maven-tool-window-actions";

test("Maven execution opens its bottom run pane", () => {
  expect(resolveMavenRunPaneUpdate()).toEqual({
    bottomPaneActiveTab: "maven",
    isBottomPaneVisible: true,
  });
});
