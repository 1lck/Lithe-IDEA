import { beforeEach, expect, test } from "bun:test";
import fixture from "../../../../../../shared/fixtures/lsp/project-preparation-v1.json";
import {
  beginProjectPreparation,
  clearProjectPreparation,
  getProjectPreparation,
  projectPreparationStore,
  updateProjectPreparation,
  type ProjectPreparation,
} from "./project-preparation.store";

beforeEach(() => projectPreparationStore.setState({ entries: {} }));

test("old events and cleanup cannot replace a restarted workspace session", () => {
  beginProjectPreparation("C:\\project", "old");
  beginProjectPreparation("c:/project/", "new");
  updateProjectPreparation("C:/project", "old", {
    phase: "ready",
    status: "ready",
    blocksRun: false,
  });
  clearProjectPreparation("C:/project", "old");
  expect(getProjectPreparation("c:/project")?.sessionId).toBe("new");
  expect(getProjectPreparation("c:/project")?.blocksRun).toBe(true);
  clearProjectPreparation("c:/project", "new");
  expect(getProjectPreparation("c:/project")).toBeUndefined();
});

test("shared stages stay scoped to their workspace without blocking unrelated workspaces", () => {
  beginProjectPreparation("C:/one", "one");
  beginProjectPreparation("C:/two", "two");
  for (const snapshot of fixture.snapshots as ProjectPreparation[]) {
    updateProjectPreparation("C:/one", "one", snapshot as ProjectPreparation);
    expect(getProjectPreparation("C:/one")).toEqual({ ...snapshot, sessionId: "one" });
    expect(getProjectPreparation("C:/two")?.phase).toBe("starting");
  }
});
